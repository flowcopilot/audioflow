defmodule AudioFlow.Telephony.WebSocket do
  @moduledoc """
  Twilio Media Streams and Telnyx PCMU WebSock endpoint. Requires `:provider`
  (`:twilio` or `:telnyx`), `:session` options and a 16 kHz `:vad` detector.
  Authenticate the upgrade in the host Plug before calling WebSockAdapter.
  See `docs/transports.md` for provider configuration and limits.
  """
  @behaviour WebSock
  alias AudioFlow.Telephony.{MuLaw, RateConverter}
  alias AudioFlow.WebSocket, as: PCM

  @impl true
  def init(options) do
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
       down: %RateConverter{},
       pending: <<>>,
       output_rate: nil,
       last_chunk: nil,
       playout: :queue.new(),
       playout_timer: nil,
       max_playout_packets: positive(options, :max_playout_packets, 500),
       reorder: %{},
       reorder_bytes: 0,
       gap_timer: nil,
       reorder_window: positive(options, :reorder_window, 32),
       reorder_max_bytes: positive(options, :reorder_max_bytes, 64_000),
       reorder_timeout_ms: positive(options, :reorder_timeout_ms, 200),
       output?: false
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
      translate(PCM.init(state.options), %{state | stream: id})
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
    chunk =
      case media["chunk"] do
        value when is_integer(value) and value > 0 ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {number, ""} when number > 0 -> number
            _ -> nil
          end

        _ ->
          nil
      end

    case Base.decode64(payload) do
      {:ok, bytes} when byte_size(bytes) > 0 and byte_size(bytes) <= 16_000 and chunk != nil ->
        if state.provider == :telnyx do
          reorder(chunk, bytes, state)
        else
          if state.last_chunk == nil or chunk == state.last_chunk + 1,
            do: deliver(chunk, bytes, state),
            else: fail(:unordered_media, state)
        end

      _ ->
        fail(:invalid_payload, state)
    end
  end

  # Start at chunk 1 even if the first packet received is chunk 2.
  # First copy wins; stale/duplicate packets never enter the resampler twice.
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
          other -> other
        end
    end
  end

  defp deliver(chunk, bytes, state) do
    {data, up} = RateConverter.up(MuLaw.decode(bytes), state.up)

    translate(
      PCM.handle_in({data, opcode: :binary}, state.pcm),
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

  defp positive(options, key, default) do
    value = Keyword.get(options, key, default)
    unless is_integer(value) and value > 0, do: raise(ArgumentError, "#{key} must be positive")
    value
  end

  @impl true
  def handle_info({__MODULE__, :playout, token}, %{playout_timer: {_, token}} = state) do
    case :queue.out(state.playout) do
      {{:value, frame}, queue} ->
        state = schedule_playout(%{state | playout: queue, playout_timer: nil})
        {:push, [frame], state}

      {:empty, _} ->
        {:ok, %{state | playout_timer: nil}}
    end
  end

  def handle_info({__MODULE__, :playout, _}, state), do: {:ok, state}

  def handle_info({__MODULE__, :gap_timeout, token}, %{gap_timer: {_, token}} = state),
    do: fail(:media_gap_timeout, state)

  def handle_info({__MODULE__, :gap_timeout, _}, state), do: {:ok, state}

  def handle_info({PCM, :push, _key, audio, {from, tag}}, state)
      when audio.sample_rate not in [8000, 16_000] do
    send(from, {tag, {:error, :unsupported_telephony_output_rate}})
    {:ok, state}
  end

  def handle_info({PCM, :push, _key, audio, {from, tag}}, state)
      when byte_size(audio.data) > state.max_playout_packets * 640 do
    send(from, {tag, {:error, :telephony_output_too_large}})
    fail(:playout_limit, state)
  end

  def handle_info(_, %{pcm: nil} = state), do: {:ok, state}
  def handle_info(message, state), do: translate(PCM.handle_info(message, state.pcm), state)

  @impl true
  def terminate(reason, state) do
    cancel_timer(state.gap_timer)
    cancel_timer(state.playout_timer)
    if state.pcm, do: PCM.terminate(reason, state.pcm), else: :ok
  end

  defp translate({:ok, pcm}, state), do: {:ok, %{state | pcm: pcm}}

  defp translate({:stop, reason, close, pcm}, state),
    do: {:stop, reason, close, %{state | pcm: pcm}}

  defp translate({:push, [{:text, data}] = frames, pcm}, state) do
    case JSON.decode!(data) do
      %{"type" => "error", "reason" => reason} ->
        {:stop, {:session_error, reason}, {1011, "audio session failed"}, %{state | pcm: pcm}}

      _ ->
        translate_frames(frames, pcm, state)
    end
  end

  defp translate({:push, frames, pcm}, state), do: translate_frames(frames, pcm, state)

  defp translate_frames(frames, pcm, state) do
    {frames, state} =
      Enum.reduce(frames, {[], %{state | pcm: pcm}}, fn frame, {frames, state} ->
        {new, state} = outgoing(frame, state)
        {frames ++ new, state}
      end)

    {immediate, state} =
      Enum.reduce(frames, {[], state}, fn frame, {now, state} ->
        case frame do
          {:text, data} ->
            case JSON.decode!(data)["event"] do
              "clear" ->
                cancel_timer(state.playout_timer)
                {now ++ [frame], %{state | playout: :queue.new(), playout_timer: nil}}

              "media" ->
                {now, %{state | playout: :queue.in(frame, state.playout)}}
            end
        end
      end)

    if :queue.len(state.playout) > state.max_playout_packets do
      fail(:playout_limit, state)
    else
      state = schedule_playout(state)
      if immediate == [], do: {:ok, state}, else: {:push, immediate, state}
    end
  end

  defp schedule_playout(%{playout_timer: nil} = state) do
    if :queue.is_empty(state.playout) do
      state
    else
      token = make_ref()
      timer = Process.send_after(self(), {__MODULE__, :playout, token}, 20)
      %{state | playout_timer: {timer, token}}
    end
  end

  defp schedule_playout(state), do: state

  defp outgoing({:binary, data}, state) do
    {data, down} =
      if state.output_rate == 16_000,
        do: RateConverter.down(data, state.down),
        else: {data, state.down}

    packetize(state.pending <> MuLaw.encode(data), %{state | down: down, output?: true})
  end

  defp outgoing({:text, data}, state) do
    case JSON.decode!(data) do
      %{"type" => "output_format", "sample_rate" => rate} ->
        {[], %{state | output_rate: rate, down: %RateConverter{}}}

      %{"type" => "flush"} ->
        {[wire(state, %{event: "clear"})],
         %{state | pending: <<>>, down: %RateConverter{}, output?: false}}

      %{"type" => "done"} ->
        {tail, _} =
          if state.output? and state.output_rate == 16_000,
            do: RateConverter.down(:binary.copy(<<0>>, 60), state.down),
            else: {<<>>, state.down}

        data = state.pending <> MuLaw.encode(tail)
        padding = rem(160 - rem(byte_size(data), 160), 160)

        packetize(data <> :binary.copy(<<255>>, padding), %{
          state
          | pending: <<>>,
            down: %RateConverter{},
            output?: false
        })

      %{"type" => "error"} ->
        {[], state}

      _ ->
        {[], state}
    end
  end

  defp packetize(data, state) when byte_size(data) < 160, do: {[], %{state | pending: data}}

  defp packetize(<<packet::binary-size(160), rest::binary>>, state) do
    {frames, state} = packetize(rest, state)
    {[wire(state, %{event: "media", media: %{payload: Base.encode64(packet)}}) | frames], state}
  end

  defp wire(%{provider: :twilio, stream: id}, message),
    do: {:text, JSON.encode!(Map.put(message, :streamSid, id))}

  defp wire(_state, message), do: {:text, JSON.encode!(message)}

  defp fail(reason, state) do
    cancel_timer(state.gap_timer)
    cancel_timer(state.playout_timer)

    {:stop, {:protocol_error, reason}, {1008, "invalid media stream"},
     %{
       state
       | gap_timer: nil,
         reorder: %{},
         reorder_bytes: 0,
         playout: :queue.new(),
         playout_timer: nil
     }}
  end
end
