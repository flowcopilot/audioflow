---
title: Sessions
description: Turns, events, cancellation, and limits for one conversation.
sidebar:
  order: 1
---

Each conversation is one session process. The process that starts a session is
its owner. The owner receives transcript, text, audio, and terminal events. See
the `AudioFlow` module for the event format.

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

## Lifetime

The session stops when its owner exits. Turn failures do not stop the session.
Sessions are temporary supervisor children: a session crash does not restart a
conversation with lost state. The caller must start a new session after a crash.

## Back pressure

Adapter calls acknowledge each output before they continue. The owner must
consume its mailbox. The event limit bounds output per turn, but does not bound
the owner's mailbox across turns. An adapter must also bound individual output
sizes.

:::caution
Do not pass an untrusted client directly as the owner.
:::
