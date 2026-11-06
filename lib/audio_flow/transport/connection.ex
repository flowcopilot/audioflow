defmodule AudioFlow.Transport.Connection do
  @moduledoc """
  Session lifecycle and commands shared by connection transports.

  Results contain structured `{:event, map}` and `{:audio, pcm}` events.
  Endpoints encode those events in their own wire format. An output check can
  reject PCM before the producer receives its acceptance acknowledgement.
  """
  @behaviour AudioFlow.Output
  alias AudioFlow.Audio
  alias AudioFlow.Text
  alias AudioFlow.VoiceInput

  @impl AudioFlow.Output
  def start_turn(_connection, _key), do: :ok

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

  @limits_schema [
    sample_rate: [type: :pos_integer, default: 16_000],
    max_chunk_bytes: [type: :pos_integer, default: 64_000],
    max_buffer_bytes: [type: :pos_integer, default: 960_000]
  ]

  def init(options) do
    limits =
      AudioFlow.RuntimeOptions.known!(
        options,
        @limits_schema,
        Enum.map(@limits_schema, fn {key, _} -> {key, "#{key} must be a positive integer"} end)
      )

    rate = limits[:sample_rate]
    vad = Keyword.get(options, :vad)

    input = if vad, do: VoiceInput.new(vad, Keyword.get(options, :endpoint_options, []))

    if input && input.rate != rate,
      do: raise(ArgumentError, "sample_rate must match the detector rate #{input.rate}")

    state = %{
      session: nil,
      session_ref: nil,
      input: input,
      rate: rate,
      max_chunk_bytes: limits[:max_chunk_bytes],
      max_buffer_bytes: limits[:max_buffer_bytes],
      buffer: [],
      buffer_bytes: 0,
      turn: nil,
      next_turn: 1,
      output_check: Keyword.get(options, :output_check, fn _ -> :ok end),
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
        {:events, [event(ready)], state}

      {:error, reason} ->
        {:stop, {:session_start, reason}, {1011, "session start failed"}, state}
    end
  end

  def audio(data, state) do
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

  def command(command, state), do: reply(run_command(command, state))

  def handle_info({__MODULE__, :push, {session, ref}, audio, {from, tag}}, state) do
    if state.session == session and match?({^ref, _}, state.turn) do
      case state.output_check.(audio) do
        :ok ->
          send(from, {tag, :ok})
          {format, state} = output_format(audio.sample_rate, state)
          reply(format ++ [{:audio, audio.data}], state)

        {:error, reason} ->
          send(from, {tag, {:error, reason}})
          {:output_rejected, reason, state}
      end
    else
      send(from, {tag, {:error, :stale_turn}})
      {:ok, state}
    end
  end

  def handle_info({__MODULE__, :flush, {session, _ref}}, %{session: session} = state),
    do: reply([event(%{type: :flush})], state)

  def handle_info({AudioFlow, session, ref, event}, %{session: session, turn: {ref, id}} = state) do
    case event do
      {:done, metrics} ->
        reply([event(%{type: :done, turn: id, metrics: metrics})], %{state | turn: nil})

      {:cancelled, _metrics} ->
        reply([event(%{type: :cancelled, turn: id})], %{state | turn: nil})

      {:error, reason, _metrics} ->
        reply([error(id, reason)], %{state | turn: nil})

      {kind, text} when kind in [:transcript, :description, :text] ->
        reply([event(%{type: kind, turn: id, text: text})], state)

      {kind, value} when kind in [:segment, :partial_transcript] ->
        reply([event(transcript_message(id, kind, value))], state)

      {kind, text, node} when kind in [:transcript, :description, :text] and is_binary(text) ->
        reply([event(%{type: kind, turn: id, text: text, node: node})], state)

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{session_ref: ref} = state),
    do: {:stop, {:session_exit, reason}, {1011, "session stopped"}, %{state | session: nil}}

  def handle_info(_message, state), do: {:ok, state}

  def terminate(_reason, %{session: session}) when is_pid(session) do
    AudioFlow.stop_session(session)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp run_command({:text, text}, state) when is_binary(text),
    do: submit(%Text{data: text}, state)

  defp run_command(:commit, %{input: nil} = state) do
    audio = %Audio{data: IO.iodata_to_binary(state.buffer), sample_rate: state.rate}
    state = %{state | buffer: [], buffer_bytes: 0}

    if audio.data == <<>>,
      do: {[error(nil, :empty_input)], state},
      else: submit(audio, state)
  end

  defp run_command(:commit, state) do
    {events, input} = VoiceInput.flush(state.input)
    voice_frames(events, %{state | input: input})
  end

  defp run_command(:cancel, state), do: cancel(state)

  defp run_command(:clear_history, state) do
    case AudioFlow.clear_history(state.session) do
      :ok -> {[event(%{type: :history_cleared})], state}
      {:error, reason} -> {[error(nil, reason)], state}
    end
  end

  defp run_command(_command, state), do: {[error(nil, :invalid_message)], state}

  defp voice_events(events, state), do: reply(voice_frames(events, state))

  defp voice_frames(events, state) do
    Enum.reduce(events, {[], state}, fn event, {frames, state} ->
      {new, state} =
        case event do
          :speech_started ->
            {cancelled, state} = cancel(state)
            {[event(%{type: :speech_started}) | cancelled], state}

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
        {[event(%{type: :turn_started, turn: id})], %{state | turn: {ref, id}, next_turn: id + 1}}

      {:error, reason} ->
        {[error(nil, reason)], state}
    end
  end

  defp cancel(state) do
    frames =
      case {AudioFlow.cancel(state.session), state.turn} do
        {:ok, nil} -> []
        {:ok, {_ref, id}} -> [event(%{type: :cancelled, turn: id})]
        {{:error, reason}, turn} -> [error(turn && elem(turn, 1), reason)]
      end

    {frames, %{state | turn: nil}}
  end

  defp output_format(rate, %{output_rate: rate} = state), do: {[], state}

  defp output_format(rate, state),
    do: {[event(%{type: :output_format, sample_rate: rate})], %{state | output_rate: rate}}

  defp error(turn, reason) do
    message = %{type: :error, reason: reason_text(reason)}
    event(if turn, do: Map.put(message, :turn, turn), else: message)
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp event(message), do: {:event, message}

  defp transcript_message(id, :partial_transcript, text),
    do: %{type: :partial_transcript, turn: id, text: text}

  defp transcript_message(id, :segment, segment) do
    %{
      type: :transcript,
      turn: id,
      text: segment.text,
      start_ms: segment.start_ms,
      end_ms: segment.end_ms,
      words: segment.words
    }
  end

  defp reply({frames, state}), do: reply(frames, state)
  defp reply([], state), do: {:ok, state}
  defp reply(frames, state), do: {:events, frames, state}
end
