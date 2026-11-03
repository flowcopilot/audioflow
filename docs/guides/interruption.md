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

Graphs do not imply text/audio alignment: branch outputs can run independently.
Graph cancellation therefore retains no new assistant text until a graph
integration provides reliable alignment. The internal synchronous
`{:speech_checkpoint, turn_ref}` Session call marks all text currently recorded
in context at the current cumulative emitted-audio end. A graph hook must call
it only after the corresponding TTS segment fully emits and before unrelated
history text is recorded; this is unsafe for unaligned concurrent branches.
The public acknowledgement API alone never invents text alignment.

## False triggers

`AudioFlow.Output.interrupt(session, transcript, min_words: 2)` returns
`{:ok, :ignored}` for fewer whitespace-delimited words, leaving the worker and
playback running. At the threshold it invokes the existing cancel/flush path.
Call this with one accumulated candidate transcript, not independent STT deltas.
It neither submits the user's next input nor changes the busy-input policy.
It is a caller-controlled heuristic, not semantic interruption detection.
After cancel, workers and queued audio have been discarded and cannot resume.
Actual pause/resume needs a pausable transport and retained generation state;
automatic false-interruption timeouts remain future work.
