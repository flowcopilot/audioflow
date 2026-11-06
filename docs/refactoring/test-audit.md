# Test review

## Baseline

The first full core run had 15 failures. Each failure occurred before the
recording behavior ran: `Store.new/1` returned `{:error, :unsafe_path}`.
The setup used `System.tmp_dir!/0`. On macOS this path can contain a symlink.
The store rejects symlinks in all path segments. This is its security contract.

## Changes

- Repair temporary directory setup in `recording_test.exs`,
  `recording_runtime_test.exs`, `cross_feature_acceptance_test.exs`, and
  `remote_providers_test.exs`. Use ExUnit's `:tmp_dir` context. It gives each test
  a directory under the project `tmp/` path. Keep all persistence, privacy,
  retention, lifecycle, permission, and symlink checks.
- In `input_processing_test.exs`, remove checks of `speaking?`,
  `semantic_checked_at`, and `reference_pending`. The returned events and PCM
  check the behavior. Check the exact utterance and detector input on both
  semantic completion cycles. A reset failure must prevent the second cycle
  from completing and thus fail the test.
- In `graph_checkpoint_test.exs`, use the audio fixture duration for playback
  acknowledgements. Do not read the session's private playout state. Branches
  emit four two-sample chunks at 16 kHz: 500,000 ns. A joined node emits no
  audio while its source is blocked. Silent and partial cases each emit one
  two-sample chunk: 125,000 ns.
- In `conversation_test.exs`, let the controlled adapter send its task PID to
  the test. Resume and failure commands go to that fixture PID. The tests no
  longer read the session's private `active.task.pid` fields. The checks still
  prove successful handoff, stale tool rejection, and rollback after failure.

No test was deleted. The reviewed negative recording checks protect current
privacy, persistence, or path security requirements. Graph catalog checks
protect public metadata. Codec reference values and dependency compatibility
checks have independent contracts. Similar tests at session and transport
levels protect different lifecycle behavior.

## Evidence

The recording owner and store, all four repaired test files, their recent
history, CI routing, input processing, voice input, graph checkpoint, playout,
conversation, graph options, retrieval, and telephony tests were read.
The test tree was searched for source checks, constant assertions, private
state access, and skip tags. No deletion candidate had enough evidence to
remove its contract.

The fixture changes add no production code or test-only production interface.
The store security rules are unchanged.

## Checks

- Recording and provider tests: 25 passed.
- Input processing and graph checkpoint tests: 8 passed.
- Conversation tests: 5 passed.
- Focused tests require local TCP access for the Mix build lock. Provider tests
  also use local sockets.
- Final core and avatar server suite: 224 passed, 3 skipped, 5 excluded.
- UI: 28 passed. Chat: 12 passed. WebRTC: 12 passed.
- Final independent review found no further issue worth fixing.
