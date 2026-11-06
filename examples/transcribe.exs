# Transcribe a mono 16-bit WAV file and print SubRip (SRT) captions.
#
#   AUDIOFLOW_ML=1 mix run examples/transcribe.exs input.wav
#   DEEPGRAM_API_KEY=... mix run examples/transcribe.exs input.wav deepgram
#   MISTRAL_API_KEY=... mix run examples/transcribe.exs input.wav mistral:voxtral-mini-latest
#
# Any ReqLLM transcription model works, for example groq:whisper-large-v3-turbo
# or openai:gpt-4o-transcribe. For a local vLLM server, set AUDIOFLOW_STT_BASE_URL.
#
# Local Whisper needs 16 kHz input. Convert other files first:
#   ffmpeg -i input.mp3 -ac 1 -ar 16000 -sample_fmt s16 input.wav
[path | rest] = System.argv()
{:ok, audio} = AudioFlow.Wav.read(path)

stt =
  case rest do
    ["deepgram"] ->
      {AudioFlow.Adapters.Deepgram,
       [
         model: "nova-3",
         segments: true,
         api_key: fn -> System.fetch_env!("DEEPGRAM_API_KEY") end
       ]}

    [model] ->
      base_url = System.get_env("AUDIOFLOW_STT_BASE_URL")

      {AudioFlow.Adapters.ReqLLMTranscription,
       [model: model, segments: true] ++
         if(String.starts_with?(model, "mistral:"),
           do: [provider_options: [timestamp_granularities: "segment"]],
           else: []
         ) ++ if(base_url, do: [base_url: base_url], else: [])}

    [] ->
      repository = "openai/whisper-tiny"
      revision = "169d4a4341b33bc18d8881c4b69c2e104e1cc0af"

      # Whisper segments get the section times. `timestamps: :segments` fails to
      # compile with the pinned Bumblebee 0.8.0 and EXLA 1.0.0.
      {:ok, whisper} = AudioFlow.Models.whisper(repository, load_options: [revision: revision])

      {:ok, _} =
        Supervisor.start_link([AudioFlow.Models.child_spec(AudioFlow.Whisper, whisper)],
          strategy: :one_for_one
        )

      {AudioFlow.NxAdapter,
       [
         serving: AudioFlow.Whisper,
         input: &AudioFlow.NxAdapter.whisper_input/1,
         output: &AudioFlow.NxAdapter.transcript_segments/1
       ]}
  end

# Deepgram accepts at most 2 MB per request, so use sections of 60 seconds or less.
{:ok, transcript} = AudioFlow.transcribe(audio, stt, chunk_ms: 30_000)
IO.puts(AudioFlow.Transcript.to_srt(transcript))
