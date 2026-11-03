---
title: Feature coverage
description: What each feature's tests and live checks establish.
---

Validated on Linux x86_64, Elixir 1.20.4 / OTP 29, 2026-11-03. The integration
branch combines PRs #26–#32 and #34–#42. None has been merged into main by this
work, and the open issues have not been manually closed. This report separates
implemented scope from live-service, device and remaining software requirements.

## Runnable apps and examples

| Entry point | Available behavior |
| --- | --- |
| `examples/chat` | Linux synthetic demo; Apple native profile; server-configured remote STT/TTS and speech-to-speech; language/voice options; redacted recordings with download/delete/retention; timing, rendered-audio progress, provisional Pause/Resume/Confirm controls. |
| `ui` | Graph editor and MCP; remote speech nodes; PCM upload/WAV output; RAG starter configuration; workflow commit/rollback example; multi-turn evaluations and optional redacted recordings. |
| `examples/rtvi-client` | Official Pipecat JS SDK custom transport, typed messages and streamed PCM playback. |
| `examples/telephony-loopback.exs` | Both carrier envelopes, reordered/duplicate Telnyx input and paced PCMU replies over real local WebSockets. |
| `examples/network` | Real local encoded audio/video publishing and PCM WebRTC-to-Session voice-agent examples. |
| `examples/avatar` | Explicitly enabled, server-backed finite LiveAvatar publication and LiveKit audio/video viewer. Requires account configuration for actual generation. |

Read each example's README for exact setup. Synthetic demos produce fixed text
and silent PCM; their successful execution does not establish inference quality.

## Issue coverage

| Issue | Implemented scope | Remaining boundary |
| --- | --- | --- |
| #5 network transport | Raw PCM WebSocket; optional ExWebRTC audio/video; PCM↔PCMU Session bridge, VAD, bounded pacing/reordering and teardown. | Browser signaling/client interoperability, TURN/NAT and production congestion/loss handling remain unverified. |
| #6 telephony | Twilio/Telnyx PCMU serializers, resampling, Telnyx reordering/gap deadlines, paced output and interruption clear. | Live carrier calls, handset playout accounting, SIP, call creation/transfers and deployment authentication remain outside the tested serializer scope. |
| #8 speech-to-speech | OpenAI Realtime and Gemini Live mixed events routed through bounded Sessions with cancellation/timeouts/output handling. | Fresh connection per committed utterance; no provider history replay, persistent duplex connection, tools or mixed-output graph/UI node. |
| #9 server audio processing | Actual SpeexDSP denoising/reference AEC before VAD and aligned reference ingress. | Synchronized PortAudio render-reference wiring and physical acoustic validation remain incomplete. |
| #10 semantic turns | Pinned Smart Turn v3.1 ONNX worker, bounded retries/silence/timeouts and explicit fallback. | Synchronous inference; caller supervises workers. No speech-accuracy or latency benchmark. |
| #11 telemetry | Existing session/turn/stage spans audited; OpenTelemetry bridge documented. | Deployment supplies collectors/exporters. |
| #12 interruption | Rendered offsets, conservative aligned heard-prefix history, minimum-word gate, bounded provisional pause/resume preserving worker/queue/history. | Pause implemented only for streamed chat Web Audio; native/network endpoints report unsupported. No automatic false-trigger classifier, within-chunk word alignment or acoustic proof. |
| #13 client protocol | Real official Pipecat JS SDK custom transport, server negotiation test and runnable client. | Not unmodified Daily/LiveKit/WebRTC SDK transport compatibility; microphone/camera and other SDKs unsupported. |
| #14 workflows/handoff | Conversation transitions, session-preserving prompt/tool handoff, commit/rollback; DAG validation preserved. | Workflow configuration remains explicit; broad autonomous multi-agent orchestration is not claimed. |
| #15 provider breadth | Deepgram STT, Cartesia/ElevenLabs streaming HTTP PCM TTS, remote graph nodes and chat controls. | Initial suggested provider set; committed-input STT and output-streaming TTS, not continuous duplex. No live accounts tested. |
| #16 evaluation | Multi-turn ExUnit helper, real tool-call assertions, dashboard/MCP evaluation and cross-feature regressions. | Scripted user input; no LLM-simulated user or automatic subjective grading. |
| #17 multilingual speech | Whisper language configuration, pinned Spanish/French/German MMS VITS graph choices, remote language/voice controls. | Real synthesis validated; intelligibility and voice quality not assessed. Apple chat local profile retains its existing model capabilities. |
| #18 RAG | `rag.retrieve`, parameterized Postgrex/pgvector, profile isolation and actual database graph routing. | Host owns ingestion, embedding compatibility, indexes and retrieval quality. |
| #19 recording | Bounded optional output-event recorder, ordered text/PCM artifacts, app controls and deletion/retention. | Original submitted text/input PCM are not owner output events; this is not complete call capture. Audio opt-in and unredacted. |
| #20 avatars | Finite LiveAvatar LITE publication, readiness gating and server-backed synchronized LiveKit receiver. | Account-backed generation/grants, live cleanup, lip-sync, acoustics and continuous provider sessions remain unverified. No LiveKit-to-ExWebRTC relay. |
| #21 privacy/retention | Configurable fail-closed transcript-redaction hook before persistence, finite store retention/deletion and safe local paths. | Regex coverage is explicit; no audio redaction, provider-side scrubbing, encryption/access-control platform or compliance certification. |

## Final combined regression runs

| Command / profile | Result |
| --- | --- |
| `mix test test examples/avatar/server_test.exs` | **193 passed**, 3 skipped, 5 excluded. Includes standalone avatar server fixtures outside the normal test directory. |
| `AUDIOFLOW_WEBRTC=1 mix test` | **196 passed**, 3 skipped, 5 excluded. Actual local two-peer ICE/DTLS/SRTP and PCM Session routing. |
| `AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 mix test` with FFmpeg on PATH | **214 passed**, 3 skipped, 15 excluded. Software media sinks; physical PortAudio unverified. |
| `cd examples/chat && CHAT_PROFILE=demo mix test` | **9 passed**. Actual engine/LiveView controls, recording, cancellation and pause state. |
| `node --test examples/chat/assets/test/audio.test.js` | **4 passed**. Web Audio fixtures verify render-clock bounds, serialized suspension/resumption, preserved sources and stale commands. |
| `cd ui && mix test` | **26 passed**. Editor, graph/MCP, examples and evaluation behavior. |
| `CHAT_PROFILE=demo mix assets.build` in chat; `mix assets.build` in UI | Both production asset builds passed. |
| `npm test`, `npm run typecheck`, `npm run build` in `examples/avatar` | **3 receiver tests**, SDK typecheck and production build passed. |
| Same commands in `examples/rtvi-client` | Actual official PipecatClient/server test, typecheck and production build passed. |
| `MIX_ENV=test mix run examples/telephony-loopback.exs` | Both formats passed; six paced PCMU response packets each. |
| `AUDIOFLOW_WEBRTC=1 MIX_ENV=test mix run examples/network/voice_agent.exs` | Actual peer negotiation, fixed Demo transcript/reply and six PCMU response packets. |
| `AUDIOFLOW_WEBRTC=1 MIX_ENV=test mix run examples/network/publish.exs` | Actual peer negotiation, 21 PCMU packets and three VP8 frames. |

The three skipped tests need opt-in native executables/model or a database.
Excluded tags include model/pipeline/distributed/HTTP-model checks. The separate
native/model/database runs below enable specific real integrations explicitly.
Protocol fixtures exercise real sockets but simulate provider messages. No
interactive browser, microphone/speaker, live provider, PSTN, TURN or acoustic
verification is implied by these results. npm also reported dependency
advisories in the existing app dependency trees; the builds passing is not an
audit clearance.

## Real native, model and database checks

The parent independently ran the following against the integrated implementations:

- Private PostgreSQL 17.11 / pgvector 0.8.2: **1 passed**, exercising cosine
  ordering, collection isolation, thresholds and actual rows through a graph.
- Cross-feature acceptance plus actual SpeexDSP 1.2.1, pinned Smart Turn ONNX
  and pgvector: **7 passed**. Includes redacted tool conversations, handoff with
  cancellation/heard history, and preprocessing before semantic submission.
- Actual pinned Spanish/French/German graph synthesis: **2 passed**. Checks valid
  non-silent 16 kHz PCM, not intelligibility or acoustic quality.

Reproduce database/native acceptance with provisioned prerequisites:

```sh
PG_BINDIR=/path/to/postgresql-with-pgvector/bin scripts/validate_pgvector.sh

AUDIOFLOW_MODEL_TESTS=1 \
AUDIOFLOW_SPEEX_EXECUTABLE=/path/to/audioflow-speex-dsp \
AUDIOFLOW_SMART_TURN_PYTHON=/path/to/python-environment/bin/python \
AUDIOFLOW_SMART_TURN_MODEL=/path/to/smart-turn-v3.1-cpu.onnx \
PG_BINDIR=/path/to/postgresql-with-pgvector/bin \
  scripts/validate_pgvector.sh test/cross_feature_acceptance_test.exs \
    test/native_input_processing_test.exs test/rag_pgvector_test.exs

AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 AUDIOFLOW_MODEL_TESTS=1 \
  mix test test/model_language_graph_test.exs
```

The database script creates and removes only its own temporary cluster; it does
not change system roles/services. Missing prerequisites and port conflicts fail
explicitly. On this host, existing `/tmp/audioflow-speex-dsp`,
`/tmp/audioflow-turn-venv` and `/tmp/audioflow-turn-model` were reused. Smart Turn
uses ONNX Runtime despite its tokenizer library's warning about absent PyTorch.
See `docs/input-processing.md` for pinned setup and hashes.

The media profile explicitly overrides Ratio 4.0.1's older optional constraint
with Decimal `~> 3.2`, retaining committed Decimal 3.2.0/Numbers 5.2.5. Regression
coverage exercises exact mixed Decimal/rational and sample-clock arithmetic.
The combined suite passes without the earlier experimental downgrade.
PortAudio's NIF cannot load `libasound.so.2` on this host; physical capture,
render-reference alignment and interruption must be validated on a device.
WebRTC native builds need matching OpenSSL development headers; see
`docs/webrtc-avatars.md` for the verified host setup.

## Continuous integration

`.github/workflows/tests.yml` runs core plus standalone avatar-server tests,
telephony loopback, Pipecat/LiveKit client tests and builds, dashboard/chat suites,
chat playback tests and both app asset builds. Earlier hosted core/dashboard/chat
and security jobs passed. Every later push triggers a fresh run; current hosted
results are available on integration PR #33 and are separate from local evidence.
Model, real database, WebRTC native and physical-device checks remain explicit
opt-in runs, not implied coverage of the default CI jobs.
