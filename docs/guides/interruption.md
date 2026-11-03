# Interruption and heard reply history

Issue #12 implementation: explicit playback acknowledgements, conservative
history truncation on cancellation, an optional minimum-word trigger gate, and
opt-in provisional pause/resume. Chat implements the pausable Web Audio endpoint;
native and network transports currently return unsupported. Device render
acknowledgements, within-chunk word alignment and automatic false-trigger
classification remain outside this implementation.

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

Chat reports its Web Audio render clock and serializes suspension/resumption
acknowledgements. PortAudio supplies no automatic rendered-frame offset here;
other network endpoints must integrate their own reports. Without reports,
zero reply text is known heard on cancellation. The existing Output behaviour
remains compatible; pausable endpoints opt into a separate extension.

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

## Provisional pause/resume

An endpoint implementing `AudioFlow.PausableOutput` accepts ordered pause and
resume commands and separately reports actual endpoint completion through
`Output.control_ack/5`. `Output.provisional(session, deadline_ms)` returns a
candidate reference. After the pause acknowledgement, resolve it with
`Output.resolve(session, candidate, :resume)` for a false trigger, or `:confirm`
to cancel. The deadline must be positive and at most 30 seconds; expiration
confirms/cancels, including when an endpoint never acknowledges. The original
turn timeout continues to apply. Legacy endpoints return `{:error, :unsupported}`.

The runtime preserves the worker, turn reference, checkpoints and history, and
backpressures at most one pending worker emit. Existing event/byte limits remain
effective. Successful generation completion during a candidate is held until
resume; failures, owner exit, explicit stop and deadline expiry discard held
output. A confirmed interruption flushes the endpoint queue and retains only
the explicitly acknowledged aligned text prefix. Stale commands and offsets
are rejected. A resumed false candidate neither starts a new turn nor rewrites
history.

Chat exposes Pause, Resume and Confirm/Stop controls using actual serialized
Web Audio suspension/resumption. Scheduled sources remain queued and progress
uses the frozen AudioContext clock while paused. This is a manual provisional
decision, not automatic VAD or proof of acoustic audibility. Native Playback,
telephony and WebRTC do not implement provisional pause. Upstream providers must
tolerate blocked emits; the chat's per-turn queue is finite rather than a sliding
latency window. See [chat setup and controls](../../examples/chat/README.md).
