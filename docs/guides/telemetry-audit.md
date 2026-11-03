# Issue #11 verification

PR [#25](https://github.com/flowcopilot/audioflow/pull/25) is merged and already
implements the issue's proposed session, turn, and stage telemetry events.
No second instrumentation layer is added here.

Evidence in this checkout:

- `lib/audio_flow/telemetry.ex` defines lifecycle events and adapter spans.
- `lib/audio_flow/session.ex` invokes lifecycle events, includes terminal
  status/metrics, and closes an active turn on session termination.
- `lib/audio_flow/graph/runner.ex` wraps graph adapter calls with node metadata.
- `test/telemetry_test.exs` covers lifecycle/stages, adapter error, cancellation,
  shutdown during an active turn, and graph node attribution.
- `site/src/content/docs/docs/guides/telemetry.md` documents native time units,
  metadata, cancellation limitations, and an `opentelemetry_telemetry` bridge
  with process propagation for stage parentage.

Verification: `mix test test/telemetry_test.exs` passed all five tests on
2026-11-03. This audit verifies the existing issue scope without closing #11.
As documented, killed turn tasks cannot emit stage stop events; the turn stop
reports cancellation/timeout instead. Session lifecycle events are not part of
the documented OpenTelemetry bridge; that bridge exports turn and stage spans.
