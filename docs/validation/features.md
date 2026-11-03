# Cross-feature validation

Evidence collected on Linux x86_64, Elixir 1.20.4 / OTP 29, 2026-11-03.
This branch starts at integration commit `be74ac5` (PR #33 including #26–#34).
It adds acceptance tests and setup documentation, not app controls or runtime code.
Results below are scoped to this checkout, not proof that all associated issues are fixed.

## Parent integration rerun

The newer combined integration branch includes #35 and #36 as well as these
acceptance tests. The parent independently verified:

- Core: **175 passed, 3 skipped, 5 excluded**.
- Private-cluster pgvector graph routing: **1 passed**.
- Cross-feature acceptance plus actual SpeexDSP, pinned Smart Turn and pgvector:
  **7 passed**, using the native/model environment below.
- Combined ML/media: **205 passed, 3 skipped, 15 excluded**, with FFmpeg on PATH
  and the committed Decimal **3.2.0** / Numbers **5.2.5** lock entries unchanged.

The optional media dependencies now explicitly override Ratio 4.0.1's older
optional Decimal constraint with `{:decimal, "~> 3.2", override: true}`. A media
compatibility regression covers Ratio's Decimal construction, Numbers mixed
Decimal/rational arithmetic, and exact sample-clock arithmetic. The real media
suite also passes. This resolves the clean-install dependency conflict described
in the historical run below without the experimental Decimal/Numbers downgrade.
Hardware PortAudio remains unverified: its NIF reports missing `libasound.so.2`;
the passing media tests use software sinks.

On the preceding combined base, the parent also passed the optional WebRTC suite
(174 tests), actual two-peer publication example, both paced telephony loopbacks,
and official PipecatClient/server test, typecheck and production build. Those
counts predate these acceptance additions. App session results remain pending.

The parent subsequently integrated app PRs #38/#39 and Session bridge #40:
dashboard **26 passed**, chat demo **7 passed**, browser playback-clock unit test
**1 passed**, and both supported `mix assets.build` commands passed. These are
LiveView/engine and JavaScript-fixture checks, not interactive browser/device
verification. The latest optional WebRTC suite passed **187 tests** (3 skipped,
5 excluded), and `examples/network/voice_agent.exs` completed actual local
ICE/DTLS/SRTP negotiation with real Session routing and explicitly synthetic
Demo inference. The encoded publication example remains independently checked.
Chat demo runs on Linux without EMLX; Apple native mode remains platform gated.

`.github/workflows/tests.yml` repeats the credential-free root, telephony,
official Pipecat SDK, dashboard and chat tests and production asset builds on
pull requests. Native model, real database, WebRTC and physical device checks
remain separate explicit commands; adding the workflow does not claim its
hosted run has already passed.

## Coverage matrix

| Capability / PR | Concrete validation | Evidence class | Example entry point / remaining boundary |
| --- | --- | --- | --- |
| Recorded/redacted multi-turn tool conversations (#26, existing tool support) | `mix test test/cross_feature_acceptance_test.exs`: HTTP SSE tool rounds execute a function, return its result to the server, preserve the successful pair on the second turn, and redact chunk-split email text on disk; audio omitted by default | Real Session, local HTTP protocol fixture; synthetic text/audio, no provider inference | `examples/demo.exs`; owner-side recording API in `docs/recording-and-privacy.md`. Recording sanitizes persisted streams, not in-memory prompts or provider tool results. |
| State handoff + cancellation + playback rollback (#29, #30, #34) | Same acceptance file: stage transition, acknowledge one complete audio chunk, cancel, reject stale ACK, retain only heard prefix in next prompt, then complete and commit a transition | Real Session/graph/history/recorder; synthetic LLM/TTS and explicit playback acknowledgement | `examples/conversation_handoff.exs` requires a supplied chat endpoint; graph checkpoint and interruption suites also cover failure and ambiguous alignment. No device playback verification. Recording intentionally contains generated text, including unheard text; it is not a heard-only transcript. |
| Remote speech routing and privacy (#28, #34) | `mix test test/remote_providers_test.exs`: actual local WebSocket handshakes/events through OpenAI/Gemini Session routes, completion/cancel/timeout/stop socket cleanup; added Gemini-to-recorder split-stream redaction. Deepgram final segments; Cartesia/ElevenLabs raw HTTP PCM and connection cleanup | Real TCP/WebSocket/HTTP protocol fixtures, simulated provider messages | `docs/providers.md` Session configuration. No live service, account entitlement, latency, or provider-model verification. Keys resolved on the server. |
| Semantic ingress + DSP (#32) | Cross-feature acceptance splits capture/reference at 300 bytes, subtracts reference before VAD, semantically commits processed utterance, verifies exact Session STT input and redacted persisted transcript | Deterministic DSP/VAD/semantic/STT fixtures, real ingress and Session routing | `docs/input-processing.md`; model/DSP execution checked separately below. |
| Native DSP + semantic model (#32) | `test/native_input_processing_test.exs`: stationary-noise attenuation, delayed-reference echo convergence, near-end retention; pinned Smart Turn hash, reference probability, deterministic inference and last-eight-second cropping | Actual SpeexDSP 1.2.1 executable and Smart Turn v3.1 ONNX CPU; synthetic signal inputs | Existing `/tmp/audioflow-speex-dsp`, `/tmp/audioflow-turn-venv`, `/tmp/audioflow-turn-model` reused without deleting them. No synchronized device render-reference tap, acoustic test, speech accuracy or latency benchmark. |
| Retrieval + graph context (#30) | `scripts/validate_pgvector.sh`: private PostgreSQL 17.11 / pgvector 0.8.2; cosine ordering, collection isolation, threshold, empty result, and real rows through `rag.retrieve` into downstream graph context | Actual database/extension; synthetic 3-D embedding and demo downstream LLM | `docs/guides/conversation-and-retrieval.md`. Ingestion, embedding model compatibility, production indexes and retrieval quality remain application responsibilities. |
| Conversation evaluation and language selection (#31) | Core conversation/evaluation suites; `AUDIOFLOW_ML=1 AUDIOFLOW_MODEL_TESTS=1 mix test test/model_language_graph_test.exs`: 2 passed, including pinned Spanish/French/German MMS graph adapters emitting non-silent valid 16 kHz PCM | Scripted conversation fixtures plus actual multilingual model inference using cached weights | `examples/conversation.exs`, `docs/guides/model-languages.md`; no intelligibility/listening evaluation. |
| Telephony/RTVI subset (#27) | Core `test/telephony_test.exs`, `test/network_protocol_test.exs` | Local protocol/codec fixtures, not a real carrier call | `docs/transports.md`; external ingress/authentication and real carrier validation remain deployment work. |
| App surfaces | UI/chat suites owned by app sessions; supported build commands attempted below | No browser/device verification in this task | Contract: server-owned credentials/profiles; demo mode must identify synthetic inference; unsupported operations must not become dead controls. App sessions own runnable UI setup and feature surfaces. |
| Newer network/avatar work | Parent reports #35/#36 integrated at `772f301` after this checkout began; not rerun here | Parent-reported evidence only, separate from this report's runs | `examples/network/README.md`, `examples/network/publish.exs` on newer base: standalone encoded peer loopback and finite LiveAvatar LITE utterances. Actual peer negotiation differs from fixture events. Encoded WebRTC does **not** establish a PCM Session bridge; dedicated follow-up pending. LiveAvatar requires real server credentials and provider prerequisites. |

## Reproduce without credentials

```sh
mix deps.get
mix test
mix test test/cross_feature_acceptance_test.exs test/remote_providers_test.exs \
  test/graph_checkpoint_test.exs test/interruption_test.exs
```

No model or service keys are needed. Demo adapters synthesize their output; these
commands do not exercise native speech recognition, LLM inference, or a paid provider.
The added tests assert behavior across real component boundaries rather than catalog labels.

For real retrieval, install PostgreSQL including `vector.control` and its matching
shared library. `initdb`, `pg_ctl`, `createdb`, and `mix` must be on PATH. On this
Nix machine the existing plugin bundle was used:

```sh
PG_BINDIR=/nix/store/3jsmc7skip0ah6v6a7di9s6ydf6c3pva-postgresql-and-plugins-17.11/bin \
  scripts/validate_pgvector.sh
# Portable alternative: PG_BINDIR=/path/to/postgresql-with-pgvector/bin
```

The script creates its own temporary cluster/user/database, listens on loopback
port 55484 (override `AUDIOFLOW_TEST_PG_PORT`), runs the real retrieval test, then
stops and removes only its own cluster on exit. It never alters system roles or
services; port conflicts fail startup. Missing vector extension fails explicitly.
For an existing disposable database the test accepts `AUDIOFLOW_PGVECTOR_URL` with
username/password, host, port and database (not arbitrary libpq query options).
Its temporary table disappears when the supervised connection stops. This task
also fixed the formerly unexecuted test's unsupported `Postgrex.start_link(url: ...)`
setup and connection teardown race.

For native DSP/semantic validation, provision the compiler/library and pinned
Python requirements/model using `docs/input-processing.md`, then run:

```sh
AUDIOFLOW_MODEL_TESTS=1 \
AUDIOFLOW_SPEEX_EXECUTABLE=/tmp/audioflow-speex-dsp \
AUDIOFLOW_SMART_TURN_PYTHON=/tmp/audioflow-turn-venv/bin/python \
AUDIOFLOW_SMART_TURN_MODEL=/tmp/audioflow-turn-model/smart-turn-v3.1-cpu.onnx \
  mix test test/native_input_processing_test.exs
```

This ran with actual native/model dependencies, not a fallback. The combined
focused run of this file, cross-feature acceptance and real pgvector passed all
**7 tests**. Smart Turn's Transformers warning about absent PyTorch/TF/Flax is
expected here: inference uses ONNX Runtime. Existing cache contents were preserved.

## Commands, results and blockers

- Baseline `mix test`: **159 passed, 3 skipped, 5 excluded**.
- With the committed lock restored, `AUDIOFLOW_PGVECTOR_URL=postgresql://audioflow@127.0.0.1:55483/audioflow_test mix test`: **164 passed, 2 skipped, 5 excluded**.
- `PG_BINDIR=/nix/store/3jsmc7skip0ah6v6a7di9s6ydf6c3pva-postgresql-and-plugins-17.11/bin scripts/validate_pgvector.sh`: **1 passed**, including actual retrieval graph routing and automatic private-cluster cleanup.
- `AUDIOFLOW_ML=1 AUDIOFLOW_MODEL_TESTS=1 mix test test/model_language_graph_test.exs`:
  **2 passed** with actual pinned multilingual cached models.
- `AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 mix deps.get`: **blocked on committed lock**.
  Ratio 4.0.1 permits Decimal 1/2, while committed Decimal is 3.2.0 and Numbers
  5.2.5 requires Decimal 3 when enabled. Experimental
  `AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 mix deps.update decimal numbers ratio`, followed
  by `AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 mix deps.get`, selected Decimal 2.4.1 and
  Numbers 5.2.4. Hex flagged Decimal advisories `EEF-CVE-2026-97853` and
  `EEF-CVE-2026-32686`. **The experimental lock is not committed or recommended
  for deployment**; the parent must resolve optional-profile compatibility.
- With that temporary lock, `AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 mix test`:
  **190 passed, 2 failed, 3 skipped, 15 excluded**; both failures were missing
  `ffmpeg`. Rerun with
  `PATH=/nix/store/rr1fzxzzv5pnz5wm6yfcxinnwid64x71-ffmpeg-8.1.2-bin/bin:$PATH AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 AUDIOFLOW_PGVECTOR_URL=postgresql://audioflow@127.0.0.1:55483/audioflow_test mix test`:
  **193 passed, 2 skipped, 15 excluded**. This is conditional experimental-lock
  evidence, not a clean-install claim for the committed combined profile.
  PortAudio NIF logs report missing `libasound.so.2`; no hardware capture/playback
  was verified. Real-model, pipeline-model, distributed and HTTP-model tags remain
  excluded unless explicitly enabled; the multilingual and Smart Turn runs above
  are the separately enabled model checks.
- In each of `ui/assets` and `examples/chat/assets`, `npm ci --ignore-scripts`
  succeeded; `npm run build` compiled CSS then rejected missing `NODE_PATH` with
  instruction to use `mix assets.build`. Running `mix assets.build` in `ui` and
  `examples/chat` failed dependency preflight: app lock files lack `mint_web_socket`,
  `jido`, and `postgrex`; chat also lacks optional ML/EMLX sources. No JavaScript
  build success is claimed. App sessions should run `mix deps.get` and the supported
  `mix assets.build` alias, which compiles colocated hooks and sets NODE_PATH.
  No app dependency locks, UI/chat tests or app source were changed here.

## Integration ownership

Changed files: `test/cross_feature_acceptance_test.exs`,
`test/remote_providers_test.exs`, `test/rag_pgvector_test.exs`,
`scripts/validate_pgvector.sh`, and this report. Provider sessions may overlap
`test/remote_providers_test.exs`; retrieval sessions may overlap the pgvector test.
No Session, VoiceInput, network implementation, app source, or dependency lock
change is included. Parent must rerun on its newer combined base and incorporate
ongoing network, PCM Session bridge, app-suite and example-surface evidence.
