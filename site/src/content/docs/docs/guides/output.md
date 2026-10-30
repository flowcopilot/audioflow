---
title: Output transport
description: Play reply audio, and flush it when the user interrupts.
sidebar:
  order: 9
---

Attach a playback process to a session:

```elixir
sink = %Membrane.PortAudio.Sink{latency: :low,
  ringbuffer_size: 2048, portaudio_buffer_size: 256}
{:ok, playback} = AudioFlow.Playback.start_link(sink: sink)
{:ok, session} = AudioFlow.start_session(
  Keyword.put(session_options, :output, {AudioFlow.Playback, playback}))
```

The application selects the sink. A sound device opens only when PCM arrives.
Each turn gets its own output pipeline. The queue is limited by `:max_bytes`
(96,000 by default). A full queue blocks the turn worker, while cancellation
stays available in the session.

## Drain and flush

Normal completion drains queued output. The playback process sends `:drained`
after pipeline cleanup. Inference `:done` can arrive before playback finishes.
Cancellation drops the queue and closes the old pipeline before it
acknowledges. Old turn references are rejected.

## Events

The observer receives `{AudioFlow.Playback, pid, turn_key, event}`. Events
include `:drained`, `{:first_buffer, %{elapsed_us: us}}`,
`{:flushed, %{control_us: us}}`, back pressure, and failure. These are not
microphone-to-speaker measurements. Acoustic interruption latency needs a
loopback recording and a common clock.

## Custom transports

`AudioFlow.Output` defines the transport interface for other output engines.
`push/3` runs in the turn worker, so it can apply back pressure. `flush/2` must
release blocked producers and stop old output. Use a separate playback process
for each session.

## Full media example

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 AUDIOFLOW_PCM=recording.s16le \
  AUDIOFLOW_LLM=Qwen/Qwen3-0.6B mix run examples/media.exs
```

This connects a PCM file, resampling, Silero, the session, and PortAudio
output. It plays sound when run.
