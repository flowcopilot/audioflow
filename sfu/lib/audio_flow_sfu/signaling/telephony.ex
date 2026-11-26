defmodule AudioFlowSFU.Signaling.Telephony do
  @moduledoc """
  Twilio and Telnyx Media Streams as room participants, at
  `/telephony/twilio` and `/telephony/telnyx`.

  The phone call joins the room as a native participant of kind `:sip`. Its
  8 kHz μ-law audio becomes a PCMU track. The audio of the other members
  comes back to the phone: PCMU as it is, Opus decoded at 8 kHz and encoded
  as μ-law. The phone call stays connected while agent nodes restart.

  The token comes from the `access_token` query parameter or, for Twilio,
  which does not allow query parameters in a stream URL, from the
  `access_token` custom parameter of the `start` message. The token room and
  identity name the participant. The stream `stop` message, or a closed
  socket, leaves the room.
  """
  @behaviour WebSock
  import Bitwise
  require Logger
  alias AudioFlowSFU.Native
  alias AudioFlowSFU.Token
  alias Membrane.Opus.Decoder.Native, as: OpusDecoder

  @impl true
  def init(%{provider: provider} = options) when provider in [:twilio, :telnyx] do
    {:ok,
     %{
       provider: provider,
       token: Map.get(options, :token),
       keys: Map.fetch!(options, :keys),
       stream: nil,
       participant: nil,
       track: nil,
       sequence: 0,
       decoders: %{}
     }}
  end

  @impl true
  def handle_in({data, opcode: :text}, state) when byte_size(data) <= 100_000 do
    case JSON.decode(data) do
      {:ok, %{"event" => event} = message} -> incoming(event, message, state)
      _ -> fail(:invalid_message, state)
    end
  end

  def handle_in(_, state), do: fail(:invalid_frame, state)

  defp incoming("connected", _, state), do: {:ok, state}

  defp incoming("start", message, %{participant: nil} = state) do
    {start, stream} =
      case state.provider do
        :twilio -> {message["start"] || %{}, get_in(message, ["start", "streamSid"])}
        :telnyx -> {message["start"] || %{}, message["stream_id"]}
      end

    token = state.token || get_in(start, ["customParameters", "access_token"]) || ""

    with true <- is_binary(stream) and stream != "",
         {:ok, grants} <- Token.verify(token, state.keys),
         {:ok, join} <-
           Native.join(grants.room, grants.identity, self(), kind: :sip, name: grants.name),
         {:ok, track} <- Native.publish_track(join.participant, "audio/PCMU", "phone") do
      Process.monitor(join.participant)
      state = %{state | stream: stream, participant: join.participant, track: track.sid}
      {:ok, Enum.reduce(join.others, state, &put_decoder(&2, &1))}
    else
      {:error, reason} -> fail(reason, state)
      _ -> fail(:unsupported_start, state)
    end
  end

  defp incoming(event, _message, %{participant: nil} = state),
    do: fail({:expected_start, event}, state)

  defp incoming("media", %{"media" => %{"payload" => payload} = media}, state)
       when is_binary(payload) do
    if media["track"] in [nil, "inbound"] do
      case Base.decode64(payload) do
        {:ok, bytes} when byte_size(bytes) in 1..16_000 -> {:ok, publish(bytes, state)}
        _ -> fail(:invalid_payload, state)
      end
    else
      {:ok, state}
    end
  end

  defp incoming("stop", _message, state), do: {:stop, :normal, state}
  defp incoming(event, _message, state) when event in ["mark", "dtmf"], do: {:ok, state}
  defp incoming(_event, _message, state), do: fail(:invalid_event, state)

  # Phone audio in 20 ms RTP packets on the PCMU track.
  defp publish(bytes, state) do
    for <<chunk::binary-size(160) <- bytes>>, reduce: state do
      state ->
        rtp = %{
          sequence_number: rem(state.sequence, 65_536),
          timestamp: rem(state.sequence * 160, 4_294_967_296),
          marker: state.sequence == 0,
          payload: chunk
        }

        send(state.participant, {:audio_flow_sfu, 1, {:rtp, state.track, rtp}})
        %{state | sequence: state.sequence + 1}
    end
  end

  @impl true
  def handle_info({:audio_flow_sfu, 1, p, {:rtp, sid, rtp}}, %{participant: p} = state) do
    {mulaw, state} = to_mulaw(sid, rtp.payload, state)
    if mulaw == <<>>, do: {:ok, state}, else: {:push, media(mulaw, state), state}
  rescue
    error ->
      Logger.debug("telephony decode failed: #{Exception.message(error)}")
      {:ok, state}
  end

  def handle_info({:audio_flow_sfu, 1, p, {:participant_joined, info}}, %{participant: p} = s),
    do: {:ok, put_decoder(s, info)}

  def handle_info({:audio_flow_sfu, 1, p, {:participant_updated, info}}, %{participant: p} = s),
    do: {:ok, put_decoder(s, info)}

  def handle_info({:audio_flow_sfu, 1, p, {:closed, _reason}}, %{participant: p} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, _, :process, p, _}, %{participant: p} = state),
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{participant: p}) when is_pid(p) do
    Native.leave(p)
  catch
    :exit, _ -> :ok
  end

  def terminate(_, _), do: :ok

  # PCMU tracks pass through; other tracks are Opus and are decoded at 8 kHz.
  defp put_decoder(state, info) do
    decoders =
      Enum.reduce(info.tracks, state.decoders, fn track, decoders ->
        Map.put_new_lazy(decoders, track.sid, fn ->
          if track.mime_type == "audio/PCMU", do: :pcmu, else: OpusDecoder.create(8000, 1)
        end)
      end)

    %{state | decoders: decoders}
  end

  defp to_mulaw(sid, payload, state) do
    case Map.get(state.decoders, sid) do
      :pcmu -> {payload, state}
      nil -> {<<>>, state}
      decoder -> {mulaw(OpusDecoder.decode_packet(decoder, payload)), state}
    end
  end

  defp media(mulaw, %{provider: :twilio} = state) do
    message = %{event: "media", streamSid: state.stream, media: %{payload: Base.encode64(mulaw)}}
    {:text, JSON.encode!(message)}
  end

  defp media(mulaw, _state),
    do: {:text, JSON.encode!(%{event: "media", media: %{payload: Base.encode64(mulaw)}})}

  defp fail(reason, state) do
    Logger.debug("telephony stream failed: #{inspect(reason)}")
    {:stop, :normal, {1008, "invalid media stream"}, state}
  end

  @doc "G.711 μ-law encoding of signed 16-bit little-endian PCM."
  def mulaw(pcm), do: for(<<sample::little-signed-16 <- pcm>>, into: <<>>, do: <<encode(sample)>>)

  @bias 0x84
  @clip 32_635

  defp encode(sample) do
    sign = if sample < 0, do: 0x80, else: 0
    magnitude = min(abs(sample), @clip) + @bias
    exponent = exponent(magnitude >>> 7, 0)
    mantissa = magnitude >>> (exponent + 3) &&& 0x0F
    bxor(sign ||| exponent <<< 4 ||| mantissa, 0xFF)
  end

  defp exponent(value, exponent) when value > 1 and exponent < 7,
    do: exponent(value >>> 1, exponent + 1)

  defp exponent(_value, exponent), do: exponent
end
