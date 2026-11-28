---
title: Sessions
description: Turns, events, cancellation, and limits for one conversation.
sidebar:
  order: 1
---

Each conversation is one session process. The process that starts a session is
its owner. The owner receives transcript, text, audio, and terminal events. See
the `AudioFlow` module for the event format.

A session without `:llm` and `:tts` only transcribes. See
[Transcription](../transcription/).

```elixir
{:ok, session} = AudioFlow.start_session(AudioFlow.Adapters.Demo.options())
audio = %AudioFlow.Audio{data: <<0, 0>>, sample_rate: 16_000}
{:ok, turn} = AudioFlow.submit(session, audio)

receive do
  {AudioFlow, ^session, ^turn, event} -> IO.inspect(event)
end
```

## Turns

Each turn has a unique reference. A session accepts one turn at a time. Further
input returns `{:error, :busy}`.

To interrupt a reply, call `cancel/1`, then submit the new utterance. With an
`:output` transport, cancellation also flushes queued output. Without a
transport, the caller must flush its playback device. Cancellation kills the
turn task. A shared hardware batch can still run to completion.

## Text input

A typed message uses `%AudioFlow.Text{data: "Hello"}`. Text turns skip speech
recognition and emit no transcript event. The trimmed text goes directly to the
language model. The reply follows the same speech synthesis and history path.
Text must be valid UTF-8, and `:max_input_bytes` applies to it.

## Audio input and limits

Audio input must be mono signed 16-bit little-endian PCM. Input limits, output
event limits, and timeouts are set per session.

| Limit | Default |
| --- | ---: |
| Input bytes | 960,000 |
| Output events per turn | 1,024 |
| Timeout | 30 seconds |

An empty transcript ends the turn without generation. Speech recognition chunks
form one prompt. Language model chunks go to speech synthesis in sequence. Use
complete sentences for language model output when possible.

## Remote and speech-to-speech adapters

For hosted Fish Audio TTS, use `AudioFlow.Adapters.FishAudioAPI` with an API
key, model and hosted voice ID. For self-hosted Fish Speech, use
`AudioFlow.Adapters.FishAudio` with a server endpoint and optional voice
reference. See [Fish Audio backends](../../features/providers/#fish-audio-hosted-api).
Native Fish inference on Nx needs a separate model/codec integration; see the
[Nx feasibility assessment](../../features/providers/#native-fish-speech-on-nx).

For OpenAI Realtime, Gemini Live or a local
[Moshi](../../features/providers/#local-moshi-speech-to-speech) server without
chained stages, use the explicit
[Session speech-to-speech mode](../../features/providers/#session-speech-to-speech-mode).
It accepts committed PCM and does not replay cross-turn history. For a
continuous conversation with the microphone open, use `AudioFlow.Duplex` with
[OpenAI Realtime](../../features/providers/#continuous-openai-realtime-conversation)
or [Moshi](../../features/providers/#continuous-full-duplex-moshi).

## Lifetime

The session stops when its owner exits. Turn failures do not stop the session.
Sessions are temporary supervisor children: a session crash does not restart a
conversation with lost state. The caller must start a new session after a crash.

## HTTP connection pool

Streaming LLM and TTS adapters hold one HTTP/1 connection for the whole turn
and share one Finch pool. When all connections to a host are in use, a new
turn waits for a connection and then fails. Size the pool for the number of
concurrent turns per host:

```elixir
config :audio_flow, :http_pool, size: 100, count: 2
```

| Option | Default | Meaning |
| --- | ---: | --- |
| `size` | 50 | Connections per pool |
| `count` | 1 | Pools per host (capacity is `size * count`) |
| `connect_timeout_ms` | 5,000 | Time to open a connection |

The pool is read when the application starts. Invalid values stop the start.

## Back pressure

Adapter calls acknowledge each output before they continue. The owner must
consume its mailbox. The event limit bounds output per turn, but does not bound
the owner's mailbox across turns. An adapter must also bound individual output
sizes.

:::caution
Do not pass an untrusted client directly as the owner.
:::
