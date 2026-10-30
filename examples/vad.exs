# AUDIOFLOW_ML=1 AUDIOFLOW_PCM=recording.s16le mix run examples/vad.exs
# Input must be mono 16 kHz signed 16-bit little-endian PCM.
source =
  System.get_env("AUDIOFLOW_SILERO_MODEL") ||
    {:hf, "onnx-community/silero-vad", "onnx/model.onnx"}

serving =
  AudioFlow.Silero.serving(source,
    load_options: [revision: "e71cae966052b992a7eca6b17738916ce0eca4ec"]
  )

{:ok, _} =
  Supervisor.start_link(
    [
      AudioFlow.Models.child_spec(AudioFlow.VAD, serving, batch_size: 4)
    ],
    strategy: :one_for_one
  )

input = AudioFlow.VoiceInput.new({AudioFlow.Silero, serving: AudioFlow.VAD})

report = fn
  :speech_started ->
    IO.puts("Speech started")

  {:utterance, audio, reason} ->
    IO.puts("Utterance: #{byte_size(audio.data)} PCM bytes, reason #{reason}")
end

input =
  System.fetch_env!("AUDIOFLOW_PCM")
  |> File.stream!(1024)
  |> Enum.reduce(input, fn pcm, state ->
    {events, state} =
      AudioFlow.VoiceInput.push(state, %AudioFlow.Audio{data: pcm, sample_rate: 16000})

    Enum.each(events, report)
    state
  end)

{events, _} = AudioFlow.VoiceInput.flush(input)
Enum.each(events, report)
