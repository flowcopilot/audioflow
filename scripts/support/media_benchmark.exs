# Shared benchmark media path. No sound device is opened.
defmodule AudioFlow.Bench.IngressSink do
  use Membrane.Sink
  def_options(vad: [spec: tuple()])

  def_input_pad(:input,
    flow_control: :auto,
    accepted_format: %Membrane.RawAudio{sample_format: :s16le, channels: 1, sample_rate: 16_000}
  )

  @impl true
  def handle_init(_, options), do: {[], AudioFlow.VoiceInput.new(options.vad)}
  @impl true
  def handle_buffer(:input, buffer, _, state) do
    {events, state} =
      AudioFlow.VoiceInput.push(state, %AudioFlow.Audio{data: buffer.payload, sample_rate: 16_000})

    {Enum.map(events, &{:notify_parent, &1}), state}
  end

  @impl true
  def handle_end_of_stream(:input, _, state) do
    {events, state} = AudioFlow.VoiceInput.flush(state)
    {Enum.map(events, &{:notify_parent, &1}), state}
  end
end

defmodule AudioFlow.Bench.Ingress do
  use Membrane.Pipeline
  @impl true
  def handle_init(_, {path, observer}) do
    alias Membrane.FFmpeg.SWResample.Converter
    format = %Membrane.RawAudio{sample_format: :s16le, channels: 1, sample_rate: 16_000}

    spec =
      child(:source, %AudioFlow.PCMFileSource{location: path, stream_format: format})
      |> child(:resampler, %Converter{
        output_stream_format: %Converter.OutputFormat{
          sample_format: :s16le,
          channels: 1,
          sample_rate: 16_000
        }
      })
      |> child(:endpoint, %AudioFlow.Bench.IngressSink{
        vad: {AudioFlow.Silero, serving: AudioFlow.Bench.VAD}
      })

    {[spec: spec], observer}
  end

  @impl true
  def handle_child_notification(event, _, _, observer) do
    send(observer, {__MODULE__, self(), event})
    {[], observer}
  end

  @impl true
  def handle_element_end_of_stream(:endpoint, :input, _, observer) do
    send(observer, {__MODULE__, self(), :eof})
    {[terminate: :normal], observer}
  end

  def handle_element_end_of_stream(_, _, _, observer), do: {[], observer}

  def read(path) do
    size = File.stat!(path).size
    if size <= 0 or size > 960_000 or rem(size, 2) != 0, do: raise("Invalid PCM input size")
    {:ok, supervisor, pipeline} = Membrane.Pipeline.start_link(__MODULE__, {path, self()})

    try do
      collect(pipeline, [])
    after
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
    end
  end

  defp collect(pipeline, utterances) do
    receive do
      {__MODULE__, ^pipeline, {:utterance, audio, _}} ->
        collect(pipeline, [audio | utterances])

      {__MODULE__, ^pipeline, :speech_started} ->
        collect(pipeline, utterances)

      {__MODULE__, ^pipeline, :eof} ->
        case utterances do
          [audio] -> audio
          _ -> raise("Each input must contain exactly one detected utterance")
        end
    after
      120_000 -> raise("Media ingress timed out")
    end
  end
end

defmodule AudioFlow.Bench.OutputSink do
  use Membrane.Sink
  def_options(observer: [spec: pid()], hold?: [spec: boolean(), default: false])

  def_input_pad(:input,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: %Membrane.RawAudio{sample_format: :s16le, channels: 1}
  )

  @impl true
  def handle_init(_, options), do: {[], options}
  @impl true
  def handle_playing(_, observer), do: {[demand: {:input, 1}], observer}
  @impl true
  def handle_buffer(:input, buffer, _, options) do
    send(
      options.observer,
      {:bench_output, buffer.payload, System.monotonic_time(:microsecond)}
    )

    {if(options.hold?, do: [], else: [demand: {:input, 1}]), options}
  end
end

defmodule AudioFlow.Bench.Native do
  def run(path, options, interrupt?) do
    {:ok, playback} =
      AudioFlow.Playback.start_link(
        sink: %AudioFlow.Bench.OutputSink{observer: self(), hold?: interrupt?}
      )

    {:ok, session} =
      AudioFlow.start_session(Keyword.put(options, :output, {AudioFlow.Playback, playback}))

    try do
      started = System.monotonic_time(:microsecond)
      audio = AudioFlow.Bench.Ingress.read(path)
      {:ok, turn} = AudioFlow.submit(session, audio)

      state = %{
        first_transcript_us: nil,
        first_text_us: nil,
        first_audio_us: nil,
        first_output_us: nil,
        duration_us: nil,
        interrupt_us: nil,
        output_bytes: 0,
        transcript: "",
        reply: "",
        status: "ok",
        utterance_sha256: sha(audio.data),
        utterance_bytes: byte_size(audio.data),
        interrupt?: interrupt?,
        cancelled?: false,
        done?: false,
        drained?: false,
        expected_bytes: 0,
        output_hash: :crypto.hash_init(:sha256),
        started: started
      }

      collect(session, turn, playback, state)
    after
      AudioFlow.stop_session(session)
      if Process.alive?(playback), do: GenServer.stop(playback)
    end
  end

  defp collect(_, _, _, %{done?: true, drained?: true} = state) do
    if not state.interrupt? and state.output_bytes != state.expected_bytes,
      do: raise("Output byte count differs from generated audio")

    state = %{state | duration_us: System.monotonic_time(:microsecond) - state.started}

    state =
      Map.put(
        state,
        :output_sha256,
        state.output_hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
      )

    state =
      Map.drop(state, [
        :interrupt?,
        :cancelled?,
        :done?,
        :drained?,
        :started,
        :expected_bytes,
        :output_hash
      ])

    if state.status == "ok" and state.output_bytes == 0, do: raise("No output audio")
    state
  end

  defp collect(session, turn, playback, state) do
    elapsed = fn -> System.monotonic_time(:microsecond) - state.started end

    state =
      receive do
        {AudioFlow, ^session, ^turn, {:transcript, text}} ->
          %{
            state
            | first_transcript_us: state.first_transcript_us || elapsed.(),
              transcript: state.transcript <> text
          }

        {AudioFlow, ^session, ^turn, {:text, text}} ->
          %{state | first_text_us: state.first_text_us || elapsed.(), reply: state.reply <> text}

        {AudioFlow, ^session, ^turn, {:audio, audio}} ->
          %{
            state
            | first_audio_us: state.first_audio_us || elapsed.(),
              expected_bytes: state.expected_bytes + byte_size(audio.data)
          }

        {:bench_output, data, at} ->
          state = %{
            state
            | first_output_us: state.first_output_us || at - state.started,
              output_bytes: state.output_bytes + byte_size(data),
              output_hash: :crypto.hash_update(state.output_hash, data)
          }

          if state.interrupt? and not state.cancelled? do
            at = System.monotonic_time(:microsecond)
            :ok = AudioFlow.cancel(session)
            us = System.monotonic_time(:microsecond) - at

            receive do
              {:bench_output, _, _} -> raise("Audio arrived after output flush")
            after
              100 -> :ok
            end

            %{state | interrupt_us: us, cancelled?: true}
          else
            state
          end

        {AudioFlow, ^session, ^turn, {:done, _}} ->
          %{state | done?: true, duration_us: elapsed.()}

        {AudioFlow, ^session, ^turn, {:cancelled, _}} ->
          %{state | done?: true, status: "cancelled", duration_us: elapsed.()}

        {AudioFlow, ^session, ^turn, {:error, reason, _}} ->
          raise("Native turn failed: #{inspect(reason)}")

        {AudioFlow.Playback, ^playback, _, :drained} ->
          %{state | drained?: true}

        {AudioFlow.Playback, ^playback, _, {:flushed, _}} ->
          %{state | drained?: true}

        {AudioFlow.Playback, ^playback, _, {:failed, reason}} ->
          raise("Output failed: #{inspect(reason)}")

        _ ->
          state
      after
        180_000 -> raise("Native benchmark timed out")
      end

    collect(session, turn, playback, state)
  end

  def sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
