# Code structure decisions

Scope: the core library, optional libraries, UI, examples, scripts, and documentation.
The initial working tree was clean. The user selected comment and test cleanup. Remove implementation comments and review tests after structural changes.

## Problems and changes

- Put session connection state and domain events in a shared transport module. Keep JSON encoding in each WebSocket endpoint.
  - RTVI and telephony call the raw PCM WebSocket handler and decode its JSON to recover events.
  - RTVI encodes commands to JSON to call the raw PCM handler.
  - Telephony intercepts private PCM output messages to enforce its output limits.
- Put PCMU conversion and packet completion in one packetizer.
  - Telephony and WebRTC copy the rate conversion, 160-byte packets, filter tail, and silence padding.
- Let adapters merge execution context through an optional adapter callback.
  - The graph runner names ReqLLM and ChatHTTP and knows their option layouts.
- Put linear PCM conversion in the resampler module, and retain its existing algorithm.
  - The graph node module owns a general audio conversion algorithm. Other callers must import graph code to use it.
- Use the core WAV encoder in the UI and chat application.
  - Three modules copy the same WAV header construction.
- Record the chat build profile in application configuration.
  - Build configuration and runtime code independently select native mode from the environment.
- Keep chat choices and defaults with their owners.
  - Chat setup validation and LiveView markup copy the mode, language, voice, and TTS choices.
  - The demo engine and native engine copy model and voice defaults.
- Let graph node families report configuration requirements.
  - UI prerequisite checks inspect the provider registry and name the RAG node and its configuration.
- Build the UI conversation example through a node catalog.
  - The example edits nested compiled conversation plans to replace adapters.
- Store each graph node family and the model adapter in its own file.
  - `graph/nodes.ex` contains four unrelated families; `graph/models.ex` contains a second module.

## Cases to retain

- PCM conversion algorithms serve different contracts: complete audio uses a sinc filter; graph linear conversion keeps its existing output; streaming telephony keeps filter state.
- Provider protocol differences, credential checks, frame bounds, reorder deadlines, playback pacing, stale message checks, and optional dependency profiles are current requirements.
- Model, distributed-node, and native pipeline tests need external resources. Their opt-in tags are required.
- Adapter and transport exception conversion keeps failures inside the documented error contract.
- Site documentation and repository guides have different navigation and context. Similar text alone does not justify removing either published entry point.

## Verification

- Initial `mix test` could not start because dependencies were absent. Locked dependencies were then installed.
- Full core and avatar server suite: 224 passed, 3 skipped, 5 excluded.
- UI suite: 28 passed. Chat suite: 12 passed.
- WebRTC suites: 12 passed. Core transport checks: 25 passed.
- Browser audio checks: 4 passed. Python report checks: 5 passed.
- Core type checks, changed-code lint, formatting, and whitespace checks passed.
- Native WebRTC first failed before media handling. The downloaded SRTP library
  could not find OpenSSL 3. A link in the ignored native build cache repaired
  the local library path. No dependency source or lockfile changed.
- Native model inference and hardware media tests remain opt-in. No model
  weights or device sessions were started for this refactor.

## Final review

Independent agents checked graph execution, audio conversion, application
settings, transport events, packet completion, and test value. All accepted
findings are resolved. No further structural issue worth fixing was found in
those reviews.

The review removed unused legacy WebSocket message forwarding. Public output
callbacks still work. Tests now use current transport messages. The filter
owns its own completion length, so the packetizer does not copy that constant.
The workflow graph names its reply type without relying on node order.

The test review is recorded in [test-audit.md](test-audit.md). No tests were
deleted. Tests use observable events and audio where private state was not
needed. Required protocol and resource limits remain in place.
