# Shared model bootstrap. Run with AUDIOFLOW_ML=1. Returns {options, metadata}.
# Kokoro is the default TTS engine and needs espeak-ng for English text.
# Set AUDIOFLOW_TTS=vits to use VITS. To use another engine, set
# AUDIOFLOW_TTS_CONFIG to a script that starts a service and returns an adapter.
# Set AUDIOFLOW_LLM to a repository supported by Bumblebee.
llm_repository = System.fetch_env!("AUDIOFLOW_LLM")

{tts, tts_children, tts_metadata} =
  case System.get_env("AUDIOFLOW_TTS_CONFIG") do
    nil ->
      {serving, output, metadata} =
        case System.get_env("AUDIOFLOW_TTS", "kokoro") do
          "kokoro" ->
            voice = System.get_env("AUDIOFLOW_VOICE", "af_heart")
            repository = "onnx-community/Kokoro-82M-v1.0-ONNX"
            revision = "1939ad2a8e416c0acfeecc08a694d14ef25f2231"

            {AudioFlow.Kokoro.serving(
               voices: [voice],
               source: {:hf, repository},
               load_options: [revision: revision]
             ), &AudioFlow.Kokoro.audio/1,
             %{engine: "kokoro", repository: repository, revision: revision, voice: voice}}

          "vits" ->
            repository = "Xenova/mms-tts-eng"
            revision = "3f8955a2adbd6487ce57420620d4916de22b9dac"

            {AudioFlow.Models.text_to_speech(repository, revision: revision),
             &AudioFlow.NxAdapter.speech_audio/1,
             %{engine: "vits", repository: repository, revision: revision}}

          _ ->
            raise "AUDIOFLOW_TTS must be kokoro or vits"
        end

      adapter = {AudioFlow.NxAdapter, serving: AudioFlow.TTS, output: output}

      {adapter, [AudioFlow.Models.child_spec(AudioFlow.TTS, serving)], metadata}

    path ->
      {adapter, _} = Code.eval_file(path)
      {adapter, [], %{engine: "custom", config: path}}
  end

whisper_repository = "openai/whisper-tiny"
whisper_revision = "169d4a4341b33bc18d8881c4b69c2e104e1cc0af"

{:ok, whisper} =
  AudioFlow.Models.whisper(whisper_repository,
    load_options: [revision: whisper_revision],
    model_options: [backend: EXLA.Backend]
  )

llm_revision =
  System.get_env("AUDIOFLOW_LLM_REVISION") ||
    if(llm_repository == "Qwen/Qwen3-0.6B", do: "c1899de289a04d12100db370d81485cdf75e47ca")

llm_load = if llm_revision, do: [revision: llm_revision], else: []

{:ok, llm} =
  AudioFlow.Models.language_model(llm_repository,
    load_options: llm_load,
    model_options: [backend: EXLA.Backend],
    generation_options: [max_new_tokens: 64, strategy: %{type: :greedy_search}]
  )

prompt =
  if String.starts_with?(llm_repository, "Qwen/Qwen3"),
    do: &AudioFlow.Prompt.qwen3/1,
    else: &Function.identity/1

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
  llm:
    {AudioFlow.NxAdapter,
     serving: AudioFlow.LLM, input: prompt, output: &AudioFlow.NxAdapter.sentences/1},
  tts: tts,
  timeout_ms: 120_000,
  max_events: 4096
]

metadata = %{
  mode: "native_inference",
  hardware_label: System.get_env("AUDIOFLOW_HARDWARE"),
  whisper: %{repository: whisper_repository, revision: whisper_revision},
  llm: %{
    repository: llm_repository,
    revision: llm_revision,
    max_new_tokens: 64,
    strategy: "greedy_search",
    prompt:
      if(String.starts_with?(llm_repository, "Qwen/Qwen3"), do: "qwen3_no_think", else: "plain")
  },
  tts: tts_metadata,
  serving: %{batch_size: 1, batch_timeout_ms: 5},
  compiler: "EXLA",
  client: "automatic",
  params_backend: "EXLA.Backend"
}

{options, metadata}
