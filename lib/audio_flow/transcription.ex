defmodule AudioFlow.Transcription do
  @moduledoc """
  Transcribes long PCM audio with any STT adapter, outside a session.

  The audio is cut into sections. Each section goes to the adapter, and its
  output becomes timed `AudioFlow.Transcript.Segment` values. Times are offsets
  from the start of the full input. The result is an `AudioFlow.Transcript`.

  Without `:vad`, sections are fixed windows of `:chunk_ms`. A window boundary
  can cut a word. With `:vad`, a voice detector tuple, sections are the detected
  utterances, and silence is not sent to the adapter. The audio must then use
  the detector sample rate. `:endpoint_options` go to `AudioFlow.VoiceInput.new/2`.
  Utterance times are accurate to one detector frame.

  An adapter can emit strings, segments, or `{:partial, text}`. Strings from one
  section form one segment that spans the section. Segment times are relative
  to the section start; a segment without times gets the section bounds.
  Partial results are ignored.

  Each section runs in a supervised task with `:timeout_ms`. Up to
  `:max_concurrency` sections run at the same time; results keep their order.
  `:on_segment` receives each segment in order, in the calling process. The
  first failure stops the work and returns `{:error, {:section, index, reason}}`.
  """
  alias AudioFlow.Adapter
  alias AudioFlow.Audio
  alias AudioFlow.Transcript
  alias AudioFlow.Transcript.Segment
  alias AudioFlow.VoiceInput

  @options_schema [
    chunk_ms: [type: :pos_integer, default: 30_000],
    vad: [type: {:tuple, [:atom, :keyword_list]}],
    endpoint_options: [type: :keyword_list, default: []],
    timeout_ms: [type: :pos_integer, default: 120_000],
    max_concurrency: [type: :pos_integer, default: 1],
    on_segment: [type: {:fun, 1}]
  ]

  @doc "Options:\n\n" <> NimbleOptions.docs(@options_schema)
  def transcribe(%Audio{} = audio, {module, adapter_options} = stt, options \\ [])
      when is_atom(module) and is_list(adapter_options) do
    unless Audio.valid?(audio), do: raise(ArgumentError, "expected mono s16le PCM")
    options = NimbleOptions.validate!(options, @options_schema)

    audio
    |> sections(options)
    |> Enum.with_index()
    |> then(
      &Task.Supervisor.async_stream_nolink(
        AudioFlow.Tasks,
        &1,
        fn section ->
          run_section(stt, section)
        end,
        max_concurrency: options[:max_concurrency],
        timeout: options[:timeout_ms],
        on_timeout: :kill_task,
        ordered: true
      )
    )
    |> Enum.reduce_while({:ok, [], 0}, &collect(&1, &2, options[:on_segment]))
    |> case do
      {:ok, segments, _} -> {:ok, Transcript.new(Enum.reverse(segments))}
      error -> error
    end
  end

  defp collect({:ok, {:ok, segments}}, {:ok, acc, index}, on_segment) do
    if on_segment, do: Enum.each(segments, on_segment)
    {:cont, {:ok, Enum.reverse(segments, acc), index + 1}}
  end

  defp collect({:ok, {:error, reason}}, {:ok, _, index}, _),
    do: {:halt, {:error, {:section, index, reason}}}

  defp collect({:exit, :timeout}, {:ok, _, index}, _),
    do: {:halt, {:error, {:section, index, :timeout}}}

  defp collect({:exit, reason}, {:ok, _, index}, _),
    do: {:halt, {:error, {:section, index, {:task_exit, reason}}}}

  defp run_section(stt, {{audio, start_ms}, _index}) do
    key = make_ref()
    Process.put(key, [])

    Adapter.run(stt, audio, fn output ->
      Process.put(key, [output!(output) | Process.get(key)])
      :ok
    end)

    end_ms = start_ms + duration_ms(audio)
    {:ok, Process.get(key) |> Enum.reverse() |> segments(start_ms, end_ms)}
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    {:adapter_error, _module, reason} -> {:error, reason}
    reason -> {:error, reason}
  end

  defp output!(text) when is_binary(text), do: text
  defp output!({:partial, text}) when is_binary(text), do: nil

  defp output!(%Segment{} = segment) do
    if Segment.valid?(segment), do: segment, else: throw(:invalid_output)
  end

  defp output!(_), do: throw(:invalid_output)

  defp segments(outputs, start_ms, end_ms) do
    {timed, text} =
      Enum.reduce(outputs, {[], []}, fn
        nil, acc -> acc
        %Segment{} = segment, {timed, text} -> {[segment | timed], text}
        string, {timed, text} -> {timed, [string | text]}
      end)

    text = text |> Enum.reverse() |> Enum.join() |> String.trim()

    timed =
      timed
      |> Enum.reverse()
      |> Enum.map(&place(&1, start_ms, end_ms))

    if text == "",
      do: timed,
      else: timed ++ [%Segment{text: text, start_ms: start_ms, end_ms: end_ms}]
  end

  defp place(segment, start_ms, end_ms) do
    segment = Segment.shift(%{segment | text: String.trim(segment.text)}, start_ms)
    %{segment | start_ms: segment.start_ms || start_ms, end_ms: segment.end_ms || end_ms}
  end

  defp sections(audio, options) do
    case options[:vad] do
      nil -> windows(audio, options[:chunk_ms])
      vad -> utterances(audio, vad, options[:endpoint_options])
    end
  end

  defp windows(%Audio{data: data, sample_rate: rate}, chunk_ms) do
    size = max(2, div(rate * chunk_ms, 1000) * 2)

    Stream.unfold(0, fn
      offset when offset >= byte_size(data) ->
        nil

      offset ->
        part = binary_part(data, offset, min(size, byte_size(data) - offset))
        {{%Audio{data: part, sample_rate: rate}, div(offset * 1000, rate * 2)}, offset + size}
    end)
  end

  # Push one detector frame at a time, so an utterance ends at the current offset.
  defp utterances(%Audio{data: data, sample_rate: rate} = audio, vad, endpoint_options) do
    input = VoiceInput.new(vad, endpoint_options)

    unless input.rate == rate,
      do: raise(ArgumentError, "audio must use the detector rate of #{input.rate} Hz")

    total = byte_size(data)

    Stream.resource(
      fn -> {input, 0} end,
      fn
        :done ->
          {:halt, :done}

        {input, offset} when offset >= total ->
          {events, _} = VoiceInput.flush(input)
          {utterance_sections(events, total, audio.sample_rate), :done}

        {input, offset} ->
          size = min(input.frame_bytes, total - offset)
          frame = %Audio{data: binary_part(data, offset, size), sample_rate: rate}
          {events, input} = VoiceInput.push(input, frame)
          offset = offset + size
          {utterance_sections(events, offset, rate), {input, offset}}
      end,
      fn _ -> :ok end
    )
  end

  defp utterance_sections(events, end_offset, rate) do
    for {:utterance, audio, _reason} <- events do
      # A flushed final frame is padded, so it can extend past the input.
      {audio, div(max(0, end_offset - byte_size(audio.data)) * 1000, rate * 2)}
    end
  end

  defp duration_ms(%Audio{data: data, sample_rate: rate}),
    do: div(byte_size(data) * 1000, rate * 2)
end
