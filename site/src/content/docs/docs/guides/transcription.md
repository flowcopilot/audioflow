---
title: Transcription
description: One speech-to-text interface, transcription sessions, and long recordings.
sidebar:
  order: 12
---

## Speech-to-text interface

All speech-to-text adapters use one interface, `AudioFlow.STT`. External
services go through ReqLLM with `AudioFlow.STT.ReqLLM`. Local models go through
Bumblebee with `AudioFlow.STT.Bumblebee`. Both take the same options and give
the same output, so you can change the engine without other changes:

```elixir
voxtral = {AudioFlow.STT.ReqLLM, model: "mistral:voxtral-mini-latest", language: "en"}
deepgram = {AudioFlow.STT.ReqLLM, model: "deepgram:nova-3", segments: true}
whisper = {AudioFlow.STT.Bumblebee, model: "openai/whisper-small", language: "en"}
```

| Option | Meaning |
| --- | --- |
| `:model` | Required. A ReqLLM model, or a Hugging Face Whisper repository. |
| `:language` | An ISO 639-1 code, or `nil` (the default) for detection. |
| `:segments` | `true` to emit timed `AudioFlow.Transcript.Segment` values in place of text. |

The input is one `AudioFlow.Audio` utterance at any sample rate. The adapter
converts it for the engine. Output arrives when the engine finishes; there are
no partial results. Errors fail the turn.

| Engine | Adapter | Models |
| --- | --- | --- |
| External services | `AudioFlow.STT.ReqLLM` | Mistral Voxtral, Deepgram, OpenAI Whisper and GPT-4o transcription, Groq Whisper, ElevenLabs Scribe, OpenRouter |
| Self-hosted servers | `AudioFlow.STT.ReqLLM` with `:base_url` | vLLM with Voxtral, Qwen3-ASR or Whisper, and other OpenAI-compatible `/audio/transcriptions` servers |
| Local models | `AudioFlow.STT.Bumblebee` | Bumblebee Whisper checkpoints |

`AudioFlow.STT.ReqLLM` sends each utterance as one WAV upload. ReqLLM reads the
provider key from its environment variable, for example `MISTRAL_API_KEY` or
`DEEPGRAM_API_KEY`, or from `:api_key`, which can be a function. Other options
go to `ReqLLM.transcribe/3`. Retries are off by default, because the session
deadline bounds the turn. ReqLLM has no Deepgram provider, so AudioFlow
registers `AudioFlow.STT.DeepgramProvider` for the Deepgram `/v1/listen` API.

```elixir
local_voxtral = {AudioFlow.STT.ReqLLM,
  model: "vllm:mistralai/Voxtral-Mini-3B-2507", base_url: "http://localhost:8000/v1"}
```

With `segments: true`, the adapter asks Mistral and Deepgram for segment times.
OpenAI-compatible Whisper servers return segments without a request. GPT-4o
transcription models give only text, so the adapter then emits text. Mistral
does not accept segment times together with `:language`; the adapter then
sends only the language and emits text.

`AudioFlow.STT.Bumblebee` loads one shared serving for each model, revision,
language and serving options, through `AudioFlow.Servings`, on first use.
Bumblebee fixes the Whisper language when it builds the serving. Add
`AudioFlow.Servings` to the inference children, and call
`AudioFlow.STT.Bumblebee.preload/1` at startup, because the first load can take
minutes. `:serving_options` select the backend and compiler (EXLA by default).
The adapter converts the input to 16 kHz with `AudioFlow.Resampler`. With the
pinned Bumblebee 0.8.0 and EXLA 1.0.0, Whisper `timestamps: :segments` fails to
compile, so local segments have no times inside a session.

The graph editor has `whisper.stt` (local), `deepgram.stt` and `mistral.stt`
nodes. The remote nodes use a fixed provider and the server key.

## Transcription sessions

A session without `:llm` and `:tts` is a transcription session. Each audio turn
runs only the STT adapter and then ends with `{:done, metrics}`. Text input
returns `{:error, {:unsupported_input, :llm}}`, and `:history` is rejected.

```elixir
{:ok, session} = AudioFlow.start_session(stt: deepgram)
{:ok, turn} = AudioFlow.submit(session, audio)
```

An STT adapter can emit three kinds of values, in any session:

| Adapter output | Session event | In the prompt and history |
| --- | --- | --- |
| `text` | `{:transcript, text}` | yes |
| `%AudioFlow.Transcript.Segment{}` | `{:segment, segment}` | yes, joined with spaces |
| `{:partial, text}` | `{:partial_transcript, text}` | no |

A segment has `text`, `start_ms` and `end_ms` from the start of the turn audio,
and optional `words` with their own times. Times are `nil` when the engine does
not give them. The `AudioFlow.STT` adapters do not emit partials. A custom
adapter can emit them: a partial is an unstable hypothesis for the text that
follows the final text emitted so far. The metrics add
`first_partial_transcript_us`. The WebSocket transport sends segments as
`transcript` messages with timing fields, and partials as `partial_transcript`
messages. Recordings keep segment text and drop partials. Graph sessions do not
use these values.

## Long recordings

For a long recording, use `AudioFlow.transcribe/3`. It cuts the audio into
sections, runs the STT adapter on each section in a supervised task, and returns
an `AudioFlow.Transcript` with times from the start of the input:

```elixir
{:ok, audio} = AudioFlow.Wav.read("meeting.wav")
{:ok, transcript} = AudioFlow.transcribe(audio, voxtral, chunk_ms: 30_000, max_concurrency: 4)
transcript.text
File.write!("meeting.srt", AudioFlow.Transcript.to_srt(transcript))
```

Fixed sections can cut a word at a boundary. Set `:vad` to a voice detector
tuple to send only detected utterances; the audio must then use the detector
sample rate. Each section has its own `:timeout_ms` (120 seconds by default),
and the first failure returns `{:error, {:section, index, reason}}`.
`:on_segment` receives each segment in order. Segments without times get the
times of their section. `AudioFlow.Wav` reads only mono 16-bit PCM WAV. Convert
other files with FFmpeg. To print captions for a file:

```sh
AUDIOFLOW_ML=1 mix run examples/transcribe.exs input.wav openai/whisper-small
DEEPGRAM_API_KEY=... mix run examples/transcribe.exs input.wav deepgram:nova-3
MISTRAL_API_KEY=... mix run examples/transcribe.exs input.wav mistral:voxtral-mini-latest
```
