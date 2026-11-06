# Transcribe a mono 16-bit WAV file and print SubRip (SRT) captions.
#
#   AUDIOFLOW_ML=1 mix run examples/transcribe.exs input.wav
#   AUDIOFLOW_ML=1 mix run examples/transcribe.exs input.wav openai/whisper-small
#   DEEPGRAM_API_KEY=... mix run examples/transcribe.exs input.wav deepgram:nova-3
#   MISTRAL_API_KEY=... mix run examples/transcribe.exs input.wav mistral:voxtral-mini-latest
#
# A name with a provider prefix, such as groq:whisper-large-v3-turbo, is an
# external service through ReqLLM. Any other name is a local Bumblebee Whisper
# model. For a self-hosted server, set AUDIOFLOW_STT_BASE_URL and use a vllm:
# model. Set AUDIOFLOW_STT_LANGUAGE to an ISO 639-1 code to skip detection.
# Convert other file formats first:
#   ffmpeg -i input.mp3 -ac 1 -ar 16000 -sample_fmt s16 input.wav
[path | rest] = System.argv()
{:ok, audio} = AudioFlow.Wav.read(path)
model = List.first(rest, "openai/whisper-tiny")
common = [model: model, language: System.get_env("AUDIOFLOW_STT_LANGUAGE"), segments: true]

stt =
  if String.contains?(model, ":") do
    base_url = System.get_env("AUDIOFLOW_STT_BASE_URL")
    {AudioFlow.STT.ReqLLM, common ++ if(base_url, do: [base_url: base_url], else: [])}
  else
    {:ok, _} = AudioFlow.Servings.start_link()
    revision = if model == "openai/whisper-tiny", do: "169d4a4341b33bc18d8881c4b69c2e104e1cc0af"
    options = common ++ [revision: revision]
    {:ok, _} = AudioFlow.STT.Bumblebee.preload(options)
    {AudioFlow.STT.Bumblebee, options}
  end

{:ok, transcript} = AudioFlow.transcribe(audio, stt, chunk_ms: 30_000)
IO.puts(AudioFlow.Transcript.to_srt(transcript))
