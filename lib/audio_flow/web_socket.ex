defmodule AudioFlow.WebSocket do
  @moduledoc """
  Raw PCM WebSocket transport for one conversation.

  This is a `WebSock` handler. Mount it with an adapter such as `WebSockAdapter`:

      WebSockAdapter.upgrade(conn, AudioFlow.WebSocket,
        [session: AudioFlow.Adapters.Demo.options(), vad: {Detector, []}],
        max_frame_size: 1_000_000)

  Each connection starts one session and owns it. The session stops when the
  connection closes. The client never becomes the session owner. The
  connection is also the session's `AudioFlow.Output` transport, so it
  replaces an `:output` option. A turn worker waits until the connection
  accepts each output chunk.

  ## Options

    * `:session` - session options for `AudioFlow.start_session/1`. Required.
    * `:vad` - voice detector tuple. With a detector, the connection streams
      input through `AudioFlow.VoiceInput`. Confirmed speech cancels the active
      reply, and an endpoint submits the utterance. Without a detector, input
      collects until the client sends `commit`.
    * `:endpoint_options` - options for `AudioFlow.VoiceInput.new/2`.
    * `:sample_rate` - input sample rate (16,000). With a detector, the rate
      must match the detector rate.
    * `:max_chunk_bytes` - largest binary input frame (64,000).
    * `:max_buffer_bytes` - largest committed utterance (960,000).

  ## Client messages

  A binary frame is mono signed 16-bit little-endian PCM at the input rate.
  It must contain whole samples. A text frame is a JSON object:

    * `{"type": "text", "text": "Hello"}` submits a typed message.
    * `{"type": "commit"}` submits collected input. With a detector, it ends
      the current utterance.
    * `{"type": "cancel"}` cancels the active reply.
    * `{"type": "clear_history"}` clears saved history while idle.

  ## Server messages

  A binary frame is mono s16le output PCM for the current turn. An
  `output_format` message with `sample_rate` comes before the first binary
  frame and before each change of sample rate. Other messages are JSON objects
  with a `type` field:

    * `ready` with the `input` format and `mode` (`"vad"` or `"commit"`)
    * `speech_started` when the detector confirms speech
    * `flush` when the client must discard queued playback
    * `turn_started`, `transcript`, `description`, `text`, `done`, and
      `cancelled`, each with the connection-local integer `turn`
    * `history_cleared`
    * `error` with a `reason`, and a `turn` when a turn failed

  Graph node text events include a `node` field. Image and vector node outputs
  are not sent. After a cancellation, the connection drops output from the old
  turn.
  """
  @behaviour WebSock
  @behaviour AudioFlow.Output
  alias AudioFlow.{Audio, Text, VoiceInput}

  @impl AudioFlow.Output
  def start_turn(_connection, _key), do: :ok

  # The connection can call the session while the session calls these
  # functions, so only `push/3` waits for the connection.
  @impl AudioFlow.Output
  def push(connection, key, audio) do
    ref = Process.monitor(connection)
    send(connection, {__MODULE__, :push, key, audio, {self(), ref}})

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _, reason} ->
        {:error, {:connection_exit, reason}}
    end
  end

  @impl AudioFlow.Output
  def finish(_connection, _key), do: :ok

  @impl AudioFlow.Output
  def flush(connection, key) do
    send(connection, {__MODULE__, :flush, key})
    :ok
  end

  @impl WebSock
  def init(options) do
    rate = Keyword.get(options, :sample_rate, 16_000)
    vad = Keyword.get(options, :vad)

    unless is_integer(rate) and rate > 0,
      do: raise(ArgumentError, "sample_rate must be a positive integer")

    input = if vad, do: VoiceInput.new(vad, Keyword.get(options, :endpoint_options, []))

    if input && input.rate != rate,
      do: raise(ArgumentError, "sample_rate must match the detector rate #{input.rate}")

    state = %{
      session: nil,
      session_ref: nil,
      input: input,
      rate: rate,
      max_chunk_bytes: positive(options, :max_chunk_bytes, 64_000),
      max_buffer_bytes: positive(options, :max_buffer_bytes, 960_000),
      buffer: [],
      buffer_bytes: 0,
      turn: nil,
      next_turn: 1,
      output_rate: nil
    }

    session_options =
      options
      |> Keyword.fetch!(:session)
      |> Keyword.merge(owner: self(), output: {__MODULE__, self()})

    case AudioFlow.start_session(session_options) do
      {:ok, session} ->
        ready = %{
          type: :ready,
          mode: if(input, do: :vad, else: :commit),
          input: %{encoding: :pcm_s16le, sample_rate: rate, channels: 1}
        }

        state = %{state | session: session, session_ref: Process.monitor(session)}
        {:push, [json(ready)], state}

      {:error, reason} ->
        {:stop, {:session_start, reason}, {1011, "session start failed"}, state}
    end
  end

  @impl WebSock
  def handle_in({data, opcode: :binary}, state) do
    cond do
      byte_size(data) > state.max_chunk_bytes ->
        reply([error(nil, :chunk_too_large)], state)

      not Audio.valid?(%Audio{data: data, sample_rate: state.rate}) ->
        reply([error(nil, :invalid_audio)], state)

      state.input ->
        audio = %Audio{data: data, sample_rate: state.rate}
        {events, input} = VoiceInput.push(state.input, audio)
        voice_events(events, %{state | input: input})

      state.buffer_bytes + byte_size(data) > state.max_buffer_bytes ->
        reply([error(nil, :input_too_large)], %{state | buffer: [], buffer_bytes: 0})

      true ->
        {:ok,
         %{
           state
           | buffer: [state.buffer, :binary.copy(data)],
             buffer_bytes: state.buffer_bytes + byte_size(data)
         }}
    end
  end

  def handle_in({data, opcode: :text}, state) do
    case JSON.decode(data) do
      {:ok, %{"type" => type} = message} -> reply(command(type, message, state))
      _ -> reply([error(nil, :invalid_message)], state)
    end
  end

  @impl WebSock
  def handle_info({__MODULE__, :push, {session, ref}, audio, {from, tag}}, state) do
    if state.session == session and match?({^ref, _}, state.turn) do
      send(from, {tag, :ok})
      {format, state} = output_format(audio.sample_rate, state)
      reply(format ++ [{:binary, audio.data}], state)
    else
      send(from, {tag, {:error, :stale_turn}})
      {:ok, state}
    end
  end

  def handle_info({__MODULE__, :flush, {session, _ref}}, %{session: session} = state),
    do: reply([json(%{type: :flush})], state)

  def handle_info({AudioFlow, session, ref, event}, %{session: session, turn: {ref, id}} = state) do
    case event do
      {:done, metrics} ->
        reply([json(%{type: :done, turn: id, metrics: metrics})], %{state | turn: nil})

      {:cancelled, _metrics} ->
        reply([json(%{type: :cancelled, turn: id})], %{state | turn: nil})

      {:error, reason, _metrics} ->
        reply([error(id, reason)], %{state | turn: nil})

      {kind, text} when kind in [:transcript, :description, :text] ->
        reply([json(%{type: kind, turn: id, text: text})], state)

      {kind, text, node} when kind in [:transcript, :description, :text] and is_binary(text) ->
        reply([json(%{type: kind, turn: id, text: text, node: node})], state)

      # Audio arrives through push/3.
      _ ->
        {:ok, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{session_ref: ref} = state),
    do: {:stop, {:session_exit, reason}, {1011, "session stopped"}, %{state | session: nil}}

  # Events from a cancelled or finished turn, and unrelated messages.
  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, %{session: session}) when is_pid(session) do
    AudioFlow.stop_session(session)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp command("text", %{"text" => text}, state) when is_binary(text),
    do: submit(%Text{data: text}, state)

  defp command("commit", _message, %{input: nil} = state) do
    audio = %Audio{data: IO.iodata_to_binary(state.buffer), sample_rate: state.rate}
    state = %{state | buffer: [], buffer_bytes: 0}

    if audio.data == <<>>,
      do: {[error(nil, :empty_input)], state},
      else: submit(audio, state)
  end

  defp command("commit", _message, state) do
    {events, input} = VoiceInput.flush(state.input)
    voice_frames(events, %{state | input: input})
  end

  defp command("cancel", _message, state), do: cancel(state)

  defp command("clear_history", _message, state) do
    case AudioFlow.clear_history(state.session) do
      :ok -> {[json(%{type: :history_cleared})], state}
      {:error, reason} -> {[error(nil, reason)], state}
    end
  end

  defp command(_type, _message, state), do: {[error(nil, :invalid_message)], state}

  defp voice_events(events, state), do: reply(voice_frames(events, state))

  defp voice_frames(events, state) do
    Enum.reduce(events, {[], state}, fn event, {frames, state} ->
      {new, state} =
        case event do
          :speech_started ->
            {cancelled, state} = cancel(state)
            {[json(%{type: :speech_started}) | cancelled], state}

          {:utterance, audio, _reason} ->
            submit(audio, state)
        end

      {frames ++ new, state}
    end)
  end

  defp submit(input, state) do
    case AudioFlow.submit(state.session, input) do
      {:ok, ref} ->
        id = state.next_turn
        {[json(%{type: :turn_started, turn: id})], %{state | turn: {ref, id}, next_turn: id + 1}}

      {:error, reason} ->
        {[error(nil, reason)], state}
    end
  end

  defp cancel(state) do
    frames =
      case {AudioFlow.cancel(state.session), state.turn} do
        {:ok, nil} -> []
        {:ok, {_ref, id}} -> [json(%{type: :cancelled, turn: id})]
        {{:error, reason}, turn} -> [error(turn && elem(turn, 1), reason)]
      end

    {frames, %{state | turn: nil}}
  end

  defp output_format(rate, %{output_rate: rate} = state), do: {[], state}

  defp output_format(rate, state),
    do: {[json(%{type: :output_format, sample_rate: rate})], %{state | output_rate: rate}}

  defp error(turn, reason) do
    message = %{type: :error, reason: reason_text(reason)}
    json(if turn, do: Map.put(message, :turn, turn), else: message)
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp json(message), do: {:text, JSON.encode!(message)}

  defp reply({frames, state}), do: reply(frames, state)
  defp reply([], state), do: {:ok, state}
  defp reply(frames, state), do: {:push, frames, state}

  defp positive(options, key, default) do
    value = Keyword.get(options, key, default)

    unless is_integer(value) and value > 0,
      do: raise(ArgumentError, "#{key} must be a positive integer")

    value
  end
end
