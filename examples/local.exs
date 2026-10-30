# Run with AUDIOFLOW_ML=1. Set AUDIOFLOW_PCM to a mono 16 kHz s16le file.
# VITS is the default TTS engine. To use another engine, set AUDIOFLOW_TTS_CONFIG
# to a script that starts its shared service and returns a TTS adapter tuple.
# Set AUDIOFLOW_LLM to a repository supported by Bumblebee.
pcm_path = System.fetch_env!("AUDIOFLOW_PCM")
llm_repository = System.fetch_env!("AUDIOFLOW_LLM")

{tts, tts_children} =
  case System.get_env("AUDIOFLOW_TTS_CONFIG") do
    nil ->
      serving =
        AudioFlow.Models.text_to_speech("Xenova/mms-tts-eng",
          revision: "3f8955a2adbd6487ce57420620d4916de22b9dac"
        )

      adapter =
        {AudioFlow.NxAdapter, serving: AudioFlow.TTS, output: &AudioFlow.NxAdapter.speech_audio/1}

      {adapter, [AudioFlow.Models.child_spec(AudioFlow.TTS, serving)]}

    path ->
      {adapter, _} = Code.eval_file(path)
      {adapter, []}
  end

{:ok, whisper} = AudioFlow.Models.whisper("openai/whisper-tiny")
{:ok, llm} = AudioFlow.Models.language_model(llm_repository)

{:ok, _supervisor} =
  Supervisor.start_link(
    [
      AudioFlow.Models.child_spec(AudioFlow.Whisper, whisper),
      AudioFlow.Models.child_spec(AudioFlow.LLM, llm)
    ] ++ tts_children,
    strategy: :one_for_one
  )

options = [
  stt:
    {AudioFlow.NxAdapter,
     serving: AudioFlow.Whisper,
     input: &AudioFlow.NxAdapter.whisper_input/1,
     output: &AudioFlow.NxAdapter.transcript/1},
  llm: {AudioFlow.NxAdapter, serving: AudioFlow.LLM, output: &AudioFlow.NxAdapter.sentences/1},
  tts: tts,
  timeout_ms: 120_000,
  max_events: 4096
]

{options, %AudioFlow.Audio{data: File.read!(pcm_path), sample_rate: 16_000}}
