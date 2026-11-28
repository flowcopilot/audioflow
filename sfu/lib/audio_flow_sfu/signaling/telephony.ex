defmodule AudioFlowSFU.Signaling.Telephony do
  @moduledoc """
  Twilio and Telnyx Media Streams as room participants, at
  `/telephony/twilio` and `/telephony/telnyx`.

  The phone call joins the room as a native participant of kind `:sip`. Its
  8 kHz μ-law audio becomes a PCMU track. The audio of the other members
  comes back to the phone as one stream: each member's audio is decoded to
  8 kHz PCM (Opus with libopus, PCMU by table), queued per member, mixed
  every 20 ms with `Membrane.AudioMixer.Adder` (a sum that clips at the
  16-bit limits) and encoded as μ-law. A queue holds 100 ms at most: when a
  member sends faster than real time, the oldest audio is dropped, so the
  delay on the phone stays bounded. The stream pauses when no member has
  audio. The phone call stays connected while agent nodes restart.

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
  alias Membrane.AudioMixer.Adder
  alias Membrane.Opus.Decoder.Native, as: OpusDecoder
  alias Membrane.RawAudio

  # One 20 ms frame of 8 kHz mono s16le audio, and how many a member may queue.
  @interval 20
  @frame 320
  @max_queue 5 * @frame

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
       # Phone audio that does not fill a 20 ms packet yet.
       inbound: <<>>,
       decoders: %{},
       # Member track SID => decoded PCM that waits for its 20 ms turn.
       queues: %{},
       mixer: Adder.init(%RawAudio{sample_format: :s16le, sample_rate: 8000, channels: 1}),
       # Monotonic time of the next 20 ms tick; nil while no audio waits.
       tick: nil
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

  # Phone audio in 20 ms RTP packets on the PCMU track. A message that does
  # not end on a packet boundary leaves its remainder for the next one.
  defp publish(bytes, state) do
    bytes = state.inbound <> bytes
    rest = byte_size(bytes) - rem(byte_size(bytes), 160)
    <<whole::binary-size(^rest), remainder::binary>> = bytes

    for <<chunk::binary-size(160) <- whole>>, reduce: %{state | inbound: remainder} do
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
    {pcm, state} = to_pcm(sid, rtp.payload, state)
    {:ok, state |> enqueue(sid, pcm) |> start_ticking()}
  rescue
    error ->
      Logger.debug("telephony decode failed: #{Exception.message(error)}")
      {:ok, state}
  end

  def handle_info({:audio_flow_sfu, 1, p, {:participant_joined, info}}, %{participant: p} = s),
    do: {:ok, put_decoder(s, info)}

  def handle_info({:audio_flow_sfu, 1, p, {:participant_updated, info}}, %{participant: p} = s),
    do: {:ok, put_decoder(s, info)}

  def handle_info({:audio_flow_sfu, 1, p, {:participant_left, info}}, %{participant: p} = s),
    do: {:ok, drop_tracks(s, info)}

  # Mixes one 20 ms frame of every member that has audio queued.
  def handle_info(:tick, state) do
    {frames, queues} = take_frames(state.queues)
    state = %{state | queues: queues}

    if frames == [] do
      {:ok, %{state | tick: nil}}
    else
      {pcm, mixer} = Adder.mix(frames, state.mixer)
      state = schedule_tick(%{state | mixer: mixer})
      {:push, media(mulaw(pcm), state), state}
    end
  end

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
          if track.mime_type == "audio/PCMU", do: :pcmu, else: %{}
        end)
      end)

    %{state | decoders: decoders}
  end

  # A queue keeps the newest audio. Whole 20 ms frames leave it per tick.
  defp enqueue(state, _sid, <<>>), do: state

  defp enqueue(state, sid, pcm) do
    queue = Map.get(state.queues, sid, <<>>) <> pcm
    skip = max(byte_size(queue) - @max_queue, 0)
    queue = binary_part(queue, skip, byte_size(queue) - skip)
    %{state | queues: Map.put(state.queues, sid, queue)}
  end

  defp take_frames(queues) do
    Enum.reduce(queues, {[], %{}}, fn
      {sid, <<frame::binary-size(@frame), rest::binary>>}, {frames, queues} ->
        {[frame | frames], if(rest == <<>>, do: queues, else: Map.put(queues, sid, rest))}

      # A short rest at the end of a packet burst plays as it is.
      {_sid, rest}, {frames, queues} ->
        {[rest | frames], queues}
    end)
  end

  defp start_ticking(%{tick: nil} = state) do
    Process.send_after(self(), :tick, @interval)
    %{state | tick: now() + @interval}
  end

  defp start_ticking(state), do: state

  # The next tick follows the last one by 20 ms, whatever the delay of this
  # one. After a long stall it restarts from now instead of catching up.
  defp schedule_tick(state) do
    next = state.tick + @interval
    next = if now() - next > 5 * @interval, do: now() + @interval, else: next
    Process.send_after(self(), :tick, max(next - now(), 0))
    %{state | tick: next}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp drop_tracks(state, info) do
    sids = Enum.map(info.tracks, & &1.sid)
    %{state | decoders: Map.drop(state.decoders, sids), queues: Map.drop(state.queues, sids)}
  end

  defp to_pcm(sid, payload, state) do
    case Map.get(state.decoders, sid) do
      :pcmu -> {mulaw_decode(payload), state}
      nil -> {<<>>, state}
      decoders -> opus(sid, decoders, payload, state)
    end
  end

  # The TOC byte says whether a packet is stereo (browsers can send
  # `stereo=1`); a stereo packet is decoded in stereo and mixed down.
  defp opus(sid, decoders, <<_::5, stereo::1, _::2, _::binary>> = payload, state) do
    channels = stereo + 1
    decoder = Map.get_lazy(decoders, channels, fn -> OpusDecoder.create(8000, channels) end)
    pcm = OpusDecoder.decode_packet(decoder, payload)
    pcm = if channels == 2, do: downmix(pcm), else: pcm
    {pcm, put_in(state.decoders[sid], Map.put(decoders, channels, decoder))}
  end

  defp opus(_sid, _decoders, _payload, state), do: {<<>>, state}

  defp downmix(pcm) do
    for <<l::little-signed-16, r::little-signed-16 <- pcm>>,
      into: <<>>,
      do: <<div(l + r, 2)::little-signed-16>>
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

  @doc "Signed 16-bit little-endian PCM of G.711 μ-law bytes."
  def mulaw_decode(mulaw),
    do: for(<<byte <- mulaw>>, into: <<>>, do: <<decode(byte)::little-signed-16>>)

  @bias 0x84
  @clip 32_635

  defp decode(byte) do
    value = bxor(byte, 0xFF)
    exponent = value >>> 4 &&& 0x07
    sample = ((((value &&& 0x0F) <<< 3) + @bias) <<< exponent) - @bias
    if (value &&& 0x80) == 0, do: sample, else: -sample
  end

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
