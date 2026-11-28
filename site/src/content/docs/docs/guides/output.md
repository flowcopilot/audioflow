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
(96,000 by default). One further chunk can wait for capacity. Each chunk must fit
within that limit. A full queue blocks the turn worker, while cancellation stays
available in the session. Membrane input prefetch is limited to one buffer; the
device has its own ring buffer. PCM chunks must keep the same sample rate
throughout a turn.

## Drain and flush

Normal completion drains queued output. The playback process sends `:drained`
after pipeline cleanup. Inference `:done` can arrive before playback finishes.
PortAudio output is padded to a whole device block and has a final ring-buffer
drain interval before close.
Cancellation drops the queue and closes the old pipeline before it
acknowledges. Old turn references are rejected. A completed inference turn can
still be cancelled while its audio is queued. Session exit also closes its output
pipeline.

## Events

The observer receives `{AudioFlow.Playback, pid, turn_key, event}`. Events
include `:drained`, `{:first_buffer, %{elapsed_us: us}}`,
`{:flushed, %{control_us: us}}`, back pressure, and failure. First-buffer time ends at the Membrane source, and flush time ends after pipeline
cleanup. Neither is a microphone-to-speaker measurement. A device close can drain
a short native buffer. Acoustic interruption latency needs a
loopback recording and a common clock.

## Custom transports

`AudioFlow.Output` defines the transport interface for other output engines.
`push/3` runs in the turn worker, so it can apply back pressure. `flush/2` must
release blocked producers and stop old output. Use a separate playback process
for each session.

`start_turn/2`, `finish/2`, `flush/2`, `pause/3` and `resume/3` run inside the
session process. They must return promptly: the session answers no call while
one runs, and a call with an `:infinity` timeout can block it for good. Hand
slow work to another process and return `{:error, reason}` on failure.

## Provisional pause

`AudioFlow.Output.provisional/2` pauses an output that supports pausing, and
`resolve/3` then confirms the interruption (`:confirm`) or resumes
(`:resume`). A resume needs the endpoint's pause acknowledgement
(`control_ack/5`) first. Before it, `resolve(session, candidate, :resume)`
returns `{:error, :not_paused}` and the candidate stays live. A turn that
finishes during the pause waits for the decision, and only the candidate
deadline bounds the wait.

## Full media example

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 AUDIOFLOW_PCM=recording.s16le \
  AUDIOFLOW_LLM=Qwen/Qwen3-0.6B mix run examples/media.exs
```

`examples/models.exs` starts shared models, and `examples/local.exs` adds a single
utterance for inference benchmarks. `examples/media.exs` connects a PCM file,
resampling, Silero, the session, and PortAudio output. It plays sound when run.

Set `AUDIOFLOW_INPUT_RATE` and `AUDIOFLOW_INPUT_CHANNELS` for other input formats.
The file example reads at processing speed, so use one utterance for this check.
A live PortAudio source follows the device clock. The media tests use a controlled
sink. They verify back pressure, drain, cancellation, pipeline failure, and cleanup
without opening a sound device.

## References

- [PortAudio plugin](https://hexdocs.pm/membrane_portaudio_plugin/)
- [Membrane sinks](https://membrane-core.hexdocs.pm/Membrane.Sink.html)
