# Recorded voice → resampler → Silero → session → shared models → playback.
# Set AUDIOFLOW_PCM and AUDIOFLOW_LLM as for examples/local.exs.
# Set AUDIOFLOW_INPUT_RATE and AUDIOFLOW_INPUT_CHANNELS to the raw file format.
# Requires AUDIOFLOW_ML=1 and AUDIOFLOW_MEDIA=1. This example plays sound.
# Model bootstrap does not read the recording. The input source reads bounded chunks.
options = Code.eval_file(Path.join(__DIR__, "models.exs")) |> elem(0)

source =
  System.get_env("AUDIOFLOW_SILERO_MODEL") ||
    {:hf, "onnx-community/silero-vad", "onnx/model.onnx"}

serving =
  AudioFlow.Silero.serving(source,
    load_options: [revision: "e71cae966052b992a7eca6b17738916ce0eca4ec"]
  )

{:ok, vad_supervisor} =
  Supervisor.start_link(
    [
      AudioFlow.Models.child_spec(AudioFlow.VAD, serving)
    ],
    strategy: :one_for_one
  )

sink = %Membrane.PortAudio.Sink{latency: :low, ringbuffer_size: 2048, portaudio_buffer_size: 256}
{:ok, playback} = AudioFlow.Playback.start_link(sink: sink)

{:ok, session} =
  AudioFlow.start_session(Keyword.put(options, :output, {AudioFlow.Playback, playback}))

format = %Membrane.RawAudio{
  sample_format: :s16le,
  channels: System.get_env("AUDIOFLOW_INPUT_CHANNELS", "1") |> String.to_integer(),
  sample_rate: System.get_env("AUDIOFLOW_INPUT_RATE", "16000") |> String.to_integer()
}

{:ok, input_supervisor, _pipeline} =
  AudioFlow.InputPipeline.start_link(
    source: %AudioFlow.PCMFileSource{
      location: System.fetch_env!("AUDIOFLOW_PCM"),
      stream_format: format
    },
    session: session,
    vad: {AudioFlow.Silero, serving: AudioFlow.VAD}
  )

defmodule MediaDemo do
  def await(session, playback, state) do
    if state.input_done? and MapSet.subset?(state.accepted, state.terminal) and
         MapSet.subset?(state.accepted, state.drained) do
      :ok
    else
      receive do
        {AudioFlow.InputPipeline, _, :end_of_stream} ->
          await(session, playback, %{state | input_done?: true})

        {AudioFlow.InputPipeline, _, {:audio_flow_input, {:ok, turn}}} ->
          await(session, playback, %{state | accepted: MapSet.put(state.accepted, turn)})

        {AudioFlow.InputPipeline, _, {:audio_flow_input, {:error, reason}}} ->
          raise "input rejected: #{inspect(reason)}"

        {AudioFlow, ^session, turn, {:done, metrics}} ->
          IO.inspect(metrics, label: "Inference complete")
          await(session, playback, %{state | terminal: MapSet.put(state.terminal, turn)})

        {AudioFlow, ^session, turn, {:cancelled, _}} ->
          await(session, playback, %{state | terminal: MapSet.put(state.terminal, turn)})

        {AudioFlow, ^session, _turn, {:error, reason, _}} ->
          raise "inference failed: #{inspect(reason)}"

        {AudioFlow, ^session, _, {kind, text}} when kind in [:transcript, :text] ->
          IO.puts("#{kind}: #{text}")
          await(session, playback, state)

        {AudioFlow.Playback, ^playback, {^session, turn}, :drained} ->
          await(session, playback, %{state | drained: MapSet.put(state.drained, turn)})

        {AudioFlow.Playback, ^playback, {^session, turn}, {:flushed, metrics}} ->
          IO.inspect(metrics, label: "Output stopped")
          await(session, playback, %{state | drained: MapSet.put(state.drained, turn)})

        {AudioFlow.Playback, ^playback, _, {:failed, reason}} ->
          raise "playback failed: #{inspect(reason)}"

        _ ->
          await(session, playback, state)
      after
        245_000 -> raise "media path timed out"
      end
    end
  end
end

try do
  MediaDemo.await(session, playback, %{
    input_done?: false,
    accepted: MapSet.new(),
    terminal: MapSet.new(),
    drained: MapSet.new()
  })
after
  if Process.alive?(input_supervisor), do: Supervisor.stop(input_supervisor)
  AudioFlow.stop_session(session)
  GenServer.stop(playback)
  Supervisor.stop(vad_supervisor)
end
