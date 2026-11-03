# Optional recordings and transcript privacy

`AudioFlow.Recording` consumes the existing owner messages. Nothing is recorded
unless the owner explicitly creates and feeds a recorder. No Session changes,
provider integrations, or native media dependencies are required.

```elixir
alias AudioFlow.{Privacy, Recording}
alias AudioFlow.Recording.Store

{:ok, store} = Store.new("/var/lib/my_app/recordings",
  max_age_ms: 86_400_000, max_records: 1000, max_bytes: 8_000_000)
{:ok, session} = AudioFlow.start_session(my_adapter_options)

# Example rule only: supply your own policy/detector for the data you handle.
redactor = Privacy.rules([{~r/customer-[0-9]+/, "[CUSTOMER]"}])
recorder = Recording.new(session, store, redactor: redactor,
  audio: false, max_events: 1024, max_bytes: 4_000_000)

# In the owner's receive loop / GenServer.handle_info:
# Always keep `next`, including after an error.
receive do
  {AudioFlow, ^session, _turn, _event} = message ->
    case Recording.consume(recorder, message) do
      {:ok, next, nil} -> {:continue, next}
      {:ok, next, id} -> {:artifact, id, next}
      {:error, reason, next} -> {:recording_error, reason, next}
    end
end
```

Feed **every** runtime event in mailbox order, including terminal events; keep
one recorder per session. Calls are synchronous and can delay the owner, so use
a dedicated owner process when disk latency matters. This limits recorder state,
not the owner's mailbox; runtime producers need their own flow control. The
session already stops when its owner exits. Monitor the session and call
`Recording.discard/1` on shutdown: unfinished turns are discarded, never falsely
marked successful. Recording errors do not change runtime inference or playback.

## Artifact contract

Each terminal `:done`, `:cancelled`, or `:error` writes one versioned JSON file.
Failed/cancelled turns retain their partial outputs and explicit status. Error
reasons and metrics are excluded because they can contain sensitive data. Limits
or redactor failures discard the entire turn, with no partial plaintext file.
Byte limits bound buffered payload plus descriptor overhead; the store separately
limits final JSON bytes, including redactor expansion and base64 PCM.

`streams` holds full redacted text for each `{kind, node}` pair (`transcript`,
`description`, `text`). Joining all chunks in a stream before redaction covers
matches split across chunks, even with interleaved audio. `events` preserves
arrival order with zero-based sequence numbers and kind/node references. Text
chunk contents and offsets are deliberately absent: redaction can change length.
Identifiers spanning *different* streams require an application-specific policy.
Node IDs are application configuration and must not contain personal data.

Set `audio: true` to save genuine **output** mono PCM as base64 `pcm_s16le` with
its sample rate in ordered events. These are PCM chunks, not WAV containers.
There is no audio redaction: voice recordings can contain all spoken PII.
Images/vectors are excluded. Original submitted input, including text-only user
input and microphone PCM, is not an owner output event and is not captured.
This records STT transcript/description and generated text/audio, not a full call
capture. No synthetic inference or acoustic quality claims are implied.

## Privacy and lifecycle

A redactor is required and runs before *any* artifact (including a temporary
file) is written. Supply `fn text -> {:ok, sanitized_text} end`, or return an
error to suppress the turn. Exceptions, throws and invalid return values fail
closed with `:redaction_failed`; callback error details are not returned/logged.
Regex rules are only explicit pattern transformations, not a generic PII detector,
compliance certification, or protection for runtime history, providers, live
owner messages or audio. Plaintext remains in bounded process memory until turn
completion; a redactor must be trusted, fast and memory bounded. For intentional
plaintext persistence only, pass `redactor: &{:ok, &1}`.

`Store.list/1` and `Store.read/2` enforce finite retention as well as writes.
`Store.cleanup/1` must be scheduled by your application during idle periods
(e.g. a supervised periodic job); no background timer is silently installed.
`Store.delete/2` deletes one generated artifact ID; use `list/1` for discovery.
The directory is private (0700); artifacts are 0600, written via a synced temporary
file and rename. Use a dedicated directory: retention manages only generated
artifact names, never recursively deletes directories, and leaves unrelated files
alone. Age uses wall-clock milliseconds in generated IDs; clock corrections can
affect expiration. Count retention keeps the newest timestamps (ties by ID).

Symlink directory components and non-regular artifact files are rejected or
ignored. IDs are strictly validated before joining paths. The directory must be
controlled by the application OS user; pathname checks do not prevent races by
another process with the same filesystem privileges. Serialize store operations
if multiple owners share a root. This is local disk storage with no encryption,
authentication, backup management or secure erasure: enforce those at deployment.
Deletion does not remove external backups or already-read copies. I/O failures
are returned to the owner, which should alert without logging sensitive content.

Interrupted writes can leave sanitized `.tmp` files. Cleanup expires matching
regular temporary files by the same age policy, while leaving fresh temporary
files alone. Final artifact count limits apply to completed JSON files.
