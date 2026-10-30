# Run with AUDIOFLOW_ML=1. Set AUDIOFLOW_PCM to a mono 16 kHz s16le file.
# Set AUDIOFLOW_TTS_CONFIG to an Elixir script that returns a TTS adapter tuple.
# That script must start its shared TTS serving, if required.
# Set AUDIOFLOW_LLM to a repository supported by Bumblebee.
tts_path = System.fetch_env!("AUDIOFLOW_TTS_CONFIG")
pcm_path = System.fetch_env!("AUDIOFLOW_PCM")
llm_repository = System.fetch_env!("AUDIOFLOW_LLM")
{tts, _} = Code.eval_file(tts_path)

{:ok, whisper} = AudioFlow.Models.whisper("openai/whisper-tiny")
{:ok, llm} = AudioFlow.Models.language_model(llm_repository)

{:ok, _supervisor} =
  Supervisor.start_link(
    [
      AudioFlow.Models.child_spec(AudioFlow.Whisper, whisper),
      AudioFlow.Models.child_spec(AudioFlow.LLM, llm)
    ],
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
  timeout_ms: 120_000
]

{options, %AudioFlow.Audio{data: File.read!(pcm_path), sample_rate: 16_000}}
