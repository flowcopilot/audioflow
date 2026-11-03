# Interruption and heard reply history

Issue #12 implementation: explicit playback acknowledgements, conservative
history truncation on cancellation, and an optional minimum-word trigger gate.
This is partial progress: device acknowledgements, word alignment and actual
pause/resume after a false interruption are not implemented.

## Transport contract

A trusted endpoint driver calls
`AudioFlow.Output.acknowledge(session, turn_ref, cumulative_nanoseconds)`
after the endpoint reports that it rendered that much PCM. For the Membrane
output use `AudioFlow.Playback.acknowledge(playback, {session, turn_ref}, ns)`;
this additionally checks the offset against PCM dispatched to the sink and
records `played_ns` in playback stats. Offsets start at zero each turn and
increase monotonically; duplicates are accepted, regressions, future offsets
and stale keys return errors. Always await this call before requesting cancel
when processing an endpoint's final progress report. Concurrent cancel wins
over later acknowledgements; these are ignored as stale.

Count mono signed 16-bit PCM samples at the output sample rate, independent of
input PTS. Each PCM chunk duration is rounded up to whole nanoseconds. Maintain
the same cumulative duration convention in the endpoint driver (the rounding
error is less than one nanosecond per chunk). A push, a sink demand, Membrane
end-of-stream, or elapsed wall time is **not** a playback acknowledgement.
Only use authenticated reports for the current turn, generated at the actual
rendering endpoint. Even a rendering acknowledgement is a transport assertion,
not proof of acoustic audibility.

PortAudio currently supplies no automatic rendered-frame offset here. Existing
browser and network transports must integrate their endpoint acknowledgements
explicitly. Without reports, zero reply text is known heard on cancellation.
No callback is added to the existing Output behaviour, so transports remain
compatible.

## History and cancellation

In the chained STT/LLM/TTS pipeline, each fully synthesized LLM text chunk
creates an audio-end/text-byte checkpoint. Cancel kills the worker and flushes
output as before, then the next prompt contains only complete text chunks whose
audio ends were acknowledged before cancellation. Cancellation computes that
prefix before flushing; it deliberately omits audio that renders during flush
or whose report arrives later. Mid-chunk text is omitted rather than guessed
using a duration ratio. Unicode boundaries are preserved. A TTS chunk producing
no audio breaks the contiguous known-spoken prefix; later chunks cannot make
that missing text heard.

The last completed generation also remains truncatable by cancel while its
audio is queued. Normal completion still commits the generated reply for
compatibility; `done` does not mean played. Starting the next turn accepts that
completed history and discards its cancellation snapshot. Clear-history removes
the snapshot, so a later cancel cannot restore cleared turns. Failed turns
retain existing history semantics.

Graph sessions now create whole-chunk checkpoints on a single active path whose
history text node feeds one streaming terminal audio node directly. A checkpoint
is made only after that text chunk's TTS call returns successfully and output
pushes have been accepted. There must be one active root, no active fan-in or
fan-out, and no other audio-producing adapter. Inactive input sources do not
prevent alignment (for example, typed and STT inputs sharing an LLM).

Branches, joined TTS, intervening text transformations and other ambiguous paths
retain no new assistant text on cancellation. Partial synthesis and missing audio
are conservative as in the chained pipeline. Failed turns roll back history and
staged conversation handoffs; cancellation may retain acknowledged aligned text
while rolling back its staged handoff. Completed handoffs remain committed when
queued playback is subsequently cancelled. Mixed speech-to-speech provider deltas
have no trustworthy alignment here and history is explicitly unsupported.

## False triggers

`AudioFlow.Output.interrupt(session, transcript, min_words: 2)` returns
`{:ok, :ignored}` for fewer whitespace-delimited words, leaving the worker and
playback running. At the threshold it invokes the existing cancel/flush path.
Call this with one accumulated candidate transcript, not independent STT deltas.
It neither submits the user's next input nor changes the busy-input policy.
It is a caller-controlled heuristic, not semantic interruption detection.
After cancel, workers and queued audio have been discarded and cannot resume.
True pause/resume remains unimplemented. It requires a separate candidate-pause
operation rather than cancel: the Output behaviour and each endpoint need
pause/resume commands with acknowledged turn-scoped played and queued offsets,
plus guarantees against rendering while paused. The runtime must preserve the
worker and buffer new generation under explicit byte/event/deadline bounds (or
backpressure it), retain unsent PCM and its text checkpoints, and define overflow,
pause-deadline, transport-failure and owner-exit behavior. A false-trigger decision
can then resume exactly that queue; a confirmed interruption discards it and
truncates from the final acknowledged played offset. Existing push/flush/finish
semantics cannot safely implement this by merely suspending a task or replaying
already dispatched PCM. Automatic false-interruption timeouts remain future work.
