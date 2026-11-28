defmodule AudioFlow.Telephony.WebSocket do
  @moduledoc """
  Twilio Media Streams and Telnyx PCMU WebSock endpoint. Requires `:provider`
  (`:twilio` or `:telnyx`), `:session` options and a 16 kHz `:vad` detector.
  Authenticate the upgrade in the host Plug before calling WebSockAdapter.
  See
  https://flowcopilot.github.io/audioflow/docs/features/transports/
  for provider configuration and limits.

  The play-out queue applies back pressure. While it holds more than
  `:max_playout_packets` packets, the endpoint keeps the producer's
  acknowledgement and sends it when playout drains the queue to that mark.
  """
  @behaviour WebSock
  alias AudioFlow.Telephony.MuLaw
  alias AudioFlow.Telephony.Packetizer
  alias AudioFlow.Telephony.RateConverter
  alias AudioFlow.Transport.Connection

  @packet_ms 20
  @max_lag_packets 3

  @limits_schema [
    max_playout_packets: [type: :pos_integer, default: 500],
    reorder_window: [type: :pos_integer, default: 32],
    reorder_max_bytes: [type: :pos_integer, default: 64_000],
    reorder_timeout_ms: [type: :pos_integer, default: 200]
  ]

  @impl true
  def init(options) do
    limits =
      AudioFlow.RuntimeOptions.known!(
        options,
        @limits_schema,
        Enum.map(@limits_schema, fn {key, _} -> {key, "#{key} must be positive"} end)
      )

    provider = Keyword.fetch!(options, :provider)
    unless provider in [:twilio, :telnyx], do: raise(ArgumentError, "unsupported provider")
    Keyword.fetch!(options, :vad) || raise ArgumentError, "telephony requires VAD"

    {:ok,
     %{
       provider: provider,
       options: Keyword.put(options, :sample_rate, 16_000),
       pcm: nil,
       stream: nil,
       up: %RateConverter{},
       packetizer: %Packetizer{},
       last_chunk: nil,
       playout: :queue.new(),
       playout_timer: nil,
       playout_deadline: nil,
       held: nil,
       max_playout_packets: limits[:max_playout_packets],
       reorder: %{},
       reorder_bytes: 0,
       gap_timer: nil,
       reorder_window: limits[:reorder_window],
       reorder_max_bytes: limits[:reorder_max_bytes],
       reorder_timeout_ms: limits[:reorder_timeout_ms]
     }}
  end

  @impl true
  def handle_in({data, opcode: :text}, state) when byte_size(data) <= 100_000 do
    case JSON.decode(data) do
      {:ok, message} when is_map(message) -> incoming(message, state)
      _ -> fail(:invalid_message, state)
    end
  end

  def handle_in(_, state), do: fail(:invalid_frame, state)

  defp incoming(%{"event" => "connected"}, state), do: {:ok, state}

  defp incoming(%{"event" => "start", "start" => start} = message, %{pcm: nil} = state)
       when is_map(start) do
    {format, id, expected} =
      case state.provider do
        :twilio ->
          {start["mediaFormat"], start["streamSid"],
           %{"encoding" => "audio/x-mulaw", "sampleRate" => 8000, "channels" => 1}}

        :telnyx ->
          {start["media_format"], message["stream_id"],
           %{"encoding" => "PCMU", "sample_rate" => 8000, "channels" => 1}}
      end

    if format == expected and is_binary(id) and id != "" do
      translate(
        Connection.init(
          Keyword.merge(state.options,
            output_check: &output_check(&1, state.max_playout_packets),
            ack: :endpoint
          )
        ),
        %{state | stream: id}
      )
    else
      fail(:unsupported_start, state)
    end
  end

  defp incoming(message, %{pcm: nil} = state),
    do: fail({:expected_start, message["event"]}, state)

  defp incoming(message, state) do
    key = if state.provider == :twilio, do: "streamSid", else: "stream_id"

    if message[key] != state.stream,
      do: fail(:wrong_stream, state),
      else: stream_message(message, state)
  end

  defp stream_message(%{"event" => "media", "media" => %{"payload" => payload} = media}, state)
       when is_binary(payload) do
    cond do
      media["track"] == "outbound" ->
        {:ok, state}

      media["track"] not in [nil, "inbound"] ->
        fail(:invalid_track, state)

      true ->
        decode_media(payload, media, state)
    end
  end

  defp stream_message(%{"event" => "stop"}, state), do: {:stop, :normal, state}
  defp stream_message(%{"event" => event}, state) when event in ["mark", "dtmf"], do: {:ok, state}
  defp stream_message(_, state), do: fail(:invalid_event, state)

  defp decode_media(payload, media, state) do
    chunk = chunk_number(media["chunk"])

    case Base.decode64(payload) do
      {:ok, bytes} when byte_size(bytes) > 0 and byte_size(bytes) <= 16_000 and chunk != nil ->
        accept_media(chunk, bytes, state)

      _ ->
        fail(:invalid_payload, state)
    end
  end

  defp chunk_number(value) when is_integer(value) and value > 0, do: value

  defp chunk_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp chunk_number(_), do: nil

  defp accept_media(chunk, bytes, %{provider: :telnyx} = state), do: reorder(chunk, bytes, state)

  defp accept_media(chunk, bytes, state) do
    if state.last_chunk == nil or chunk == state.last_chunk + 1,
      do: deliver(chunk, bytes, state),
      else: fail(:unordered_media, state)
  end

  defp reorder(chunk, bytes, state) do
    expected = (state.last_chunk || 0) + 1

    cond do
      chunk < expected or is_map_key(state.reorder, chunk) ->
        {:ok, state}

      chunk - expected > state.reorder_window or
          state.reorder_bytes + byte_size(bytes) > state.reorder_max_bytes ->
        fail(:reorder_limit, state)

      true ->
        drain(
          %{
            state
            | reorder: Map.put(state.reorder, chunk, bytes),
              reorder_bytes: state.reorder_bytes + byte_size(bytes)
          },
          []
        )
    end
  end

  defp drain(state, frames) do
    next = (state.last_chunk || 0) + 1

    case Map.pop(state.reorder, next) do
      {nil, _} ->
        state = gap_timer(state)
        if frames == [], do: {:ok, state}, else: {:push, frames, state}

      {bytes, rest} ->
        state = %{state | reorder: rest, reorder_bytes: state.reorder_bytes - byte_size(bytes)}

        case deliver(next, bytes, state) do
          {:ok, state} -> drain(state, frames)
          {:push, new, state} -> drain(state, frames ++ new)
        end
    end
  end

  defp deliver(chunk, bytes, state) do
    {data, up} = RateConverter.up(MuLaw.decode(bytes), state.up)

    translate(
      Connection.audio(data, state.pcm),
      %{state | up: up, last_chunk: chunk}
    )
  end

  defp gap_timer(%{reorder: packets} = state) when map_size(packets) == 0 do
    cancel_timer(state.gap_timer)
    %{state | gap_timer: nil}
  end

  defp gap_timer(%{gap_timer: nil} = state) do
    token = make_ref()

    timer =
      Process.send_after(self(), {__MODULE__, :gap_timeout, token}, state.reorder_timeout_ms)

    %{state | gap_timer: {timer, token}}
  end

  defp gap_timer(state), do: state

  defp cancel_timer(nil), do: :ok
  defp cancel_timer({timer, _}), do: Process.cancel_timer(timer)

  @impl true
  def handle_info({__MODULE__, :playout, token}, %{playout_timer: {_, token}} = state) do
    case :queue.out(state.playout) do
      {{:value, frame}, queue} ->
        state = %{state | playout: queue, playout_timer: nil}
        state = state |> release_held() |> idle_clock() |> schedule_playout()
        {:push, [frame], state}

      {:empty, _} ->
        {:ok, %{state | playout_timer: nil, playout_deadline: nil}}
    end
  end

  def handle_info({__MODULE__, :playout, _}, state), do: {:ok, state}

  def handle_info({__MODULE__, :gap_timeout, token}, %{gap_timer: {_, token}} = state),
    do: fail(:media_gap_timeout, state)

  def handle_info({__MODULE__, :gap_timeout, _}, state), do: {:ok, state}

  def handle_info(_, %{pcm: nil} = state), do: {:ok, state}

  def handle_info(message, state),
    do: translate(Connection.handle_info(message, state.pcm), state)

  @impl true
  def terminate(reason, state) do
    cancel_timer(state.gap_timer)
    cancel_timer(state.playout_timer)
    reply_held(state, {:error, :stale_turn})
    if state.pcm, do: Connection.terminate(reason, state.pcm), else: :ok
  end

  defp output_check(audio, limit) do
    cond do
      audio.sample_rate not in [8000, 16_000] -> {:error, :unsupported_telephony_output_rate}
      byte_size(audio.data) > limit * 640 -> {:error, :telephony_output_too_large}
      true -> :ok
    end
  end

  defp translate({:output_rejected, :unsupported_telephony_output_rate, pcm}, state),
    do: {:ok, put_pcm(state, pcm)}

  defp translate({:output_rejected, :telephony_output_too_large, pcm}, state),
    do: fail(:playout_limit, put_pcm(state, pcm))

  defp translate({:ok, pcm}, state), do: {:ok, put_pcm(state, pcm)}

  defp translate({:stop, reason, close, pcm}, state),
    do: {:stop, reason, close, put_pcm(state, pcm)}

  # A failed turn does not end the call. The connection has logged the error.
  defp translate({:events, frames, pcm}, state), do: translate_frames(frames, put_pcm(state, pcm))

  defp translate({:accepted, from, frames, pcm}, state) do
    {immediate, state} = queue_frames(frames, put_pcm(state, pcm))
    state = hold_or_ack(from, state)
    respond(immediate, schedule_playout(state))
  end

  defp translate_frames(frames, state) do
    {immediate, state} = queue_frames(frames, state)
    respond(immediate, schedule_playout(state))
  end

  defp queue_frames(frames, state) do
    {frames, state} = Connection.collect(frames, state, &outgoing/2)
    Enum.reduce(frames, {[], state}, &queue_frame/2)
  end

  defp respond([], state), do: {:ok, state}
  defp respond(immediate, state), do: {:push, immediate, state}

  defp put_pcm(state, pcm), do: release_stale(%{state | pcm: pcm})

  # Keep the producer's acknowledgement while the queue is above the mark.
  defp hold_or_ack({from, tag}, state) do
    if :queue.len(state.playout) > state.max_playout_packets do
      {ref, _id} = state.pcm.turn
      %{state | held: {from, tag, ref}}
    else
      send(from, {tag, :ok})
      state
    end
  end

  defp release_held(%{held: nil} = state), do: state

  defp release_held(state) do
    if :queue.len(state.playout) > state.max_playout_packets do
      state
    else
      reply_held(state, :ok)
      %{state | held: nil}
    end
  end

  defp release_stale(%{held: {_, _, ref}} = state) do
    case state.pcm.turn do
      {^ref, _} -> state
      _ -> clear_held(state)
    end
  end

  defp release_stale(state), do: state

  defp clear_held(state) do
    reply_held(state, {:error, :stale_turn})
    %{state | held: nil}
  end

  defp reply_held(%{held: {from, tag, _}}, result), do: send(from, {tag, result})
  defp reply_held(_state, _result), do: :ok

  defp queue_frame({:clear, frame}, {now, state}) do
    cancel_timer(state.playout_timer)
    state = clear_held(state)
    {now ++ [frame], %{state | playout: :queue.new(), playout_timer: nil, playout_deadline: nil}}
  end

  defp queue_frame({:media, frame}, {now, state}),
    do: {now, %{state | playout: :queue.in(frame, state.playout)}}

  defp schedule_playout(%{playout_timer: nil} = state) do
    if :queue.is_empty(state.playout) do
      state
    else
      token = make_ref()
      deadline = next_deadline(state.playout_deadline, System.monotonic_time(:millisecond))
      timer = Process.send_after(self(), {__MODULE__, :playout, token}, deadline, abs: true)
      %{state | playout_timer: {timer, token}, playout_deadline: deadline}
    end
  end

  defp schedule_playout(state), do: state

  # An empty queue ends the run, so the next audio starts a fresh clock.
  defp idle_clock(%{playout: queue} = state) do
    if :queue.is_empty(queue), do: %{state | playout_deadline: nil}, else: state
  end

  # Each tick follows the previous deadline, so stalls do not add up. After a
  # stall of more than a few packets the clock restarts instead of bursting.
  defp next_deadline(nil, now), do: now + @packet_ms

  defp next_deadline(previous, now) do
    next = previous + @packet_ms
    if next < now - @max_lag_packets * @packet_ms, do: now + @packet_ms, else: next
  end

  defp outgoing({:audio, data}, state) do
    {packets, packetizer} =
      Packetizer.push(
        %AudioFlow.Audio{data: data, sample_rate: state.packetizer.rate},
        state.packetizer
      )

    packet_frames(packets, %{state | packetizer: packetizer})
  end

  defp outgoing({:event, %{type: :output_format, sample_rate: rate}}, state),
    do: {[], %{state | packetizer: Packetizer.format(state.packetizer, rate)}}

  defp outgoing({:event, %{type: :flush}}, state),
    do:
      {[{:clear, wire(state, %{event: "clear"})}],
       %{state | packetizer: %Packetizer{rate: state.packetizer.rate}}}

  defp outgoing({:event, %{type: :done}}, state) do
    {packets, packetizer} = Packetizer.finish(state.packetizer)
    packet_frames(packets, %{state | packetizer: packetizer})
  end

  defp outgoing({:event, _message}, state), do: {[], state}

  defp packet_frames(packets, state),
    do:
      {Enum.map(
         packets,
         &{:media, wire(state, %{event: "media", media: %{payload: Base.encode64(&1)}})}
       ), state}

  defp wire(%{provider: :twilio, stream: id}, message),
    do: {:text, JSON.encode!(Map.put(message, :streamSid, id))}

  defp wire(_state, message), do: {:text, JSON.encode!(message)}

  defp fail(reason, state) do
    cancel_timer(state.gap_timer)
    cancel_timer(state.playout_timer)
    state = clear_held(state)

    {:stop, {:protocol_error, reason}, {1008, "invalid media stream"},
     %{
       state
       | gap_timer: nil,
         reorder: %{},
         reorder_bytes: 0,
         playout: :queue.new(),
         playout_timer: nil,
         playout_deadline: nil
     }}
  end
end
