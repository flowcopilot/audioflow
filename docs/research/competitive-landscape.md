# AudioFlow competitive landscape and feature gaps

Sources accessed: 2026-11-03. Only primary sources are cited: official docs,
GitHub repositories, API references, and pricing pages. Vendor pages change
often, so check prices and plan limits again before you use them.

## 1. AudioFlow's position

AudioFlow is an open-source **Elixir library and runtime**. It is not a hosted
platform. Each conversation runs in one OTP session. A session takes one turn
at a time and supports cancellation. Model inference goes through
engine-independent adapters, and it can run on Nx/Bumblebee in the same BEAM
or on remote BEAM worker nodes (`README.md`, `lib/audio_flow/session.ex`,
`lib/audio_flow/worker.ex`, `lib/audio_flow/router.ex`). The whole STT → LLM →
TTS path, plus VAD, embeddings, CLIP, and BLIP, can run **in-process with no
Python and no cloud** (`lib_ml/audio_flow/*.ex`, `ui/README.md`).

Compared with the market:

- **Pipecat, LiveKit Agents, and TEN** are the closest open-source frameworks.
  Each has much more transport, telephony, provider, turn-detection, and
  client-SDK coverage than AudioFlow. Each also has a commercial cloud.
- **Vapi, Retell, ElevenLabs Agents, Bland, Ultravox, and Deepgram Voice
  Agent** are hosted platforms. They sell per-minute calls with telephony,
  tools, flows, knowledge bases, testing, analytics, and compliance. AudioFlow
  does not compete with them directly. It could be the self-hosted engine
  under such a product.
- **OpenAI Realtime and Gemini Live** are speech-to-speech model APIs.
  AudioFlow has no adapter for either.
- **Membrane, Bumblebee/Nx.Serving, and Jido** are Elixir building blocks.
  AudioFlow already uses them. They are not competitors.

AudioFlow's strongest areas are local/native inference, BEAM supervision and
distribution, a controlled benchmark against Pipecat, and a typed graph editor
with an MCP endpoint. Its largest gaps are **real-time transport (WebRTC,
telephony), tool calling, semantic turn detection, echo cancellation and noise
suppression, and observability**.

## 2. Comparison table

Legend: ✅ supported · ◐ partial or through a partner · ❌ not found in primary
docs · — not applicable.

| Dimension | AudioFlow | Pipecat (+Flows, Cloud) | LiveKit Agents | OpenAI Realtime + Agents SDK | Vapi | Retell | ElevenLabs Agents | TEN | Ultravox | Bland | Deepgram Voice Agent |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Type | OSS library (Elixir) | OSS framework (Python) + cloud | OSS framework (Py/Node) + cloud | Model API + SDK | Hosted platform | Hosted platform | Hosted platform | OSS framework + Agora | Model (open weights) + hosted | Hosted platform | Hosted API |
| License | Not stated in repo | BSD-2 | Apache-2.0 | — (SDK OSS) | Proprietary | Proprietary | Proprietary | Apache-2.0 + restrictions | Open weights; hosted proprietary | Proprietary | Proprietary |
| WebRTC | ❌ | ✅ Daily, LiveKit, SmallWebRTC | ✅ native | ✅ | ✅ web SDK | ✅ web call | ✅ | ✅ Agora RTC | ◐ unverified | ✅ web SDK | ◐ browser SDK |
| WebSocket | ✅ raw PCM (`AudioFlow.WebSocket`) | ✅ | ✅ (backend) | ✅ | ✅ | ✅ custom LLM | ✅ | ✅ | ◐ | ◐ | ✅ |
| SIP / PSTN | ❌ | ✅ Twilio, Telnyx, Plivo, Exotel, Vonage, Genesys… | ✅ SIP trunks + numbers | ✅ SIP | ✅ | ✅ | ✅ | ✅ SIP ext. | ✅ | ✅ | ✅ |
| Turn detection | Silero VAD + endpoint rules | VAD + Smart Turn (audio ML) | VAD + semantic turn model | server_vad + semantic_vad | ✅ configurable | ✅ managed | ✅ proprietary model | TEN VAD + Turn Detection | Model-native | ✅ managed | ✅ endpointing |
| Barge-in | ✅ cancel + flush | ✅ | ✅ adaptive, false-interrupt resume | ✅ | ✅ | ✅ sensitivity | ✅ | ✅ | ✅ | ✅ | ✅ |
| Echo cancel / noise | ❌ (browser AEC in example only) | ✅ Krisp, Koala, RNNoise, ai-coustics | ✅ Cloud noise/BVC | ❌ in VAD guide | ✅ denoising | ✅ | ◐ | ◐ | ❌ | ◐ | ❌ |
| Speech-to-speech models | ❌ | ✅ OpenAI, Gemini, Nova Sonic, Ultravox… | ✅ OpenAI, Gemini, Grok | ✅ native | ✅ OpenAI Realtime, GPT-Live | ✅ GPT-Live | ✅ realtime models | ✅ | ✅ native | ❌ | — |
| Tool calling in call | ❌ (rejected) | ✅ | ✅ (+ frontend tools) | ✅ + MCP | ✅ + MCP | ✅ | ✅ client/webhook/code/MCP | ✅ | ✅ | ✅ | ✅ |
| Flows / state machine | ◐ static DAG graph | ✅ Flows | ✅ tasks, workflows | ◐ handoffs | ✅ Squads | ✅ conversation flow | ✅ workflows | ✅ graph | ✅ call stages | ✅ pathways | ❌ |
| Multi-agent handoff | ❌ (Jido supervised, not wired) | ✅ | ✅ | ✅ | ✅ Squads | ✅ agent transfer | ✅ | ◐ | ◐ | ◐ | ✅ |
| Provider breadth | Local Nx + any OpenAI-compatible chat | ~35 STT, ~30 LLM, ~60 TTS | Many plugins + Inference | OpenAI | Many | Many | ElevenLabs + LLMs | Many | Own model | Own + some | Deepgram + LLMs |
| Multilingual | ◐ Whisper multilingual; TTS English only | ✅ (Smart Turn 23 langs) | ✅ | ✅ | ✅ | ✅ | ✅ 31–70+ | ✅ | ✅ 26 langs | ✅ 40+ | ✅ |
| Observability | ◐ turn metrics, benchmark CSV | ✅ OpenTelemetry, Sentry, Whisker | ✅ insights, OTel, recordings | ✅ tracing | ✅ logs, recording, boards | ✅ analytics, QA | ✅ analysis, search | ◐ | ✅ transcripts, recordings | ✅ | ◐ |
| Eval / simulation | ◐ benchmark only | ◐ unverified | ✅ unit tests, simulations | ◐ | ✅ simulations, evals | ✅ simulation tests, A/B | ✅ tests, experiments | ❌ | ❌ | ✅ evaluations | ❌ |
| Hosting / scaling | Self-host BEAM; distributed workers | Pipecat Cloud / Enterprise (K8s) | LiveKit Cloud / self-host / K8s | OpenAI | Hosted | Hosted | Hosted | Self-host | Hosted | Hosted / on-prem | Hosted |
| HIPAA / SOC 2 | ❌ (no hosted service) | ❌ on Cloud intro page | ✅ BAA (Scale+), SOC 2 II | — | ✅ HIPAA add-on, SOC 2 II | ✅ SOC 2, HIPAA BAA | ✅ BAA (Enterprise) | ❌ | ❌ | ✅ SOC 2 II, HIPAA, PCI | ❌ |
| PII redaction | ❌ | ❌ | ✅ | ❌ | ◐ tool encryption | ◐ privacy settings | ◐ retention | ❌ | ❌ | ❌ | ❌ |
| Client SDKs | ❌ (LiveView example) | ✅ JS, React, RN, iOS, Android, C++ | ✅ web, mobile | ✅ JS/Py | ✅ web | ✅ web, iOS, Android, RN, Flutter | ✅ React, Swift, Kotlin, RN, Unity | ◐ | ✅ | ✅ web | ✅ browser |
| Visual builder | ✅ canvas + MCP | ◐ Flows editor (unverified) | ✅ Agent Builder | ❌ | ✅ dashboard | ✅ flow builder | ✅ workflow builder | ✅ TMAN Designer | ❌ | ✅ pathways | ❌ |
| Knowledge base / RAG | ◐ embeddings only | ◐ mem0, retrieval plug-ins | ◐ examples | ◐ file search via tools | ✅ | ✅ | ✅ | ◐ | ✅ | ✅ | ❌ |
| Video / vision input | ✅ frames, BLIP, CLIP | ✅ Moondream, Gemini | ✅ | ✅ images | ❌ | ❌ | ❌ | ◐ | ❌ | ❌ | ❌ |
| Avatars | ❌ | ✅ Tavus, HeyGen, Simli | ✅ Anam, Tavus | ❌ | ❌ | ❌ | ❌ | ✅ Trulience, HeyGen, Tavus | ❌ | ❌ | ❌ |
| Pricing | Free (self-host) | OSS free; Cloud usage-based | Free tier; $0.01/agent-min | Per token | $0.05/min + providers | ~$0.07–0.31/min | ~$0.08/min + LLM | OSS | Unverified | Unverified | Unverified |

Gemini Live (model API): WebSocket, audio + 1 FPS image input, barge-in,
function calling, 70 languages ([docs](https://aistudio.google.com/docs/live-api)).
Daily is a transport (see §3).

## 3. Per-product notes

### Pipecat, Pipecat Flows, Pipecat Cloud

- The license is BSD-2-Clause. Transports include Daily, LiveKit, SmallWebRTC, FastAPI WebSocket, WebSocket server, Vonage, and WhatsApp ([README](https://github.com/pipecat-ai/pipecat)).
- Telephony serializers include Twilio, Telnyx, Plivo, Exotel, Genesys, Vonage, and community ones for Asterisk and FreeSWITCH ([supported services](https://docs.pipecat.ai/server/services/supported-services)).
- Speech-to-speech services include OpenAI Realtime, Gemini Live, AWS Nova Sonic, Azure Voice Live, Grok Voice Agent, and Ultravox ([supported services](https://docs.pipecat.ai/server/services/supported-services)).
- Smart Turn v3 is an audio-native turn model: Whisper Tiny base, about 8M parameters, 23 languages, BSD-2, about 10–100 ms inference ([smart-turn](https://github.com/pipecat-ai/smart-turn)).
- Noise filters include Krisp VIVA, Koala, RNNoise, and ai-coustics ([supported services](https://docs.pipecat.ai/server/services/supported-services)).
- OpenTelemetry spans go conversation → turn → stt/llm/tts. Attributes include TTFB, token usage, and `turn.was_interrupted`. Any OTLP exporter works ([OpenTelemetry](https://docs.pipecat.ai/server/utilities/opentelemetry)).
- Client SDKs are JS, React, React Native, iOS, Android, and C++, all on the open RTVI protocol ([client intro](https://docs.pipecat.ai/client/introduction)).
- Flows (structured dialogues) is now part of core as `pipecat.flows` (since 1.5.0). The standalone repo was archived 2026-07-05 ([pipecat-flows](https://github.com/pipecat-ai/pipecat-flows)).
- Pipecat Cloud is hosted by Daily in US, EU, and India regions, with scale-from-zero, per-session metrics, and logs. Enterprise runs in your own K8s ([Cloud intro](https://docs.pipecat.ai/deployment/pipecat-cloud/introduction)).

### LiveKit Agents

- The license is Apache-2.0. Python and Node SDKs are available. Transport is WebRTC, with SIP for telephony ([intro](https://docs.livekit.io/agents/)).
- The default turn detector "predicts end of turn from both the meaning of speech and its acoustic properties." Other modes are VAD, STT endpointing, realtime-model, and manual push-to-talk. Interruption has an adaptive mode, false-interruption resume, and history truncated to what the user heard ([turns](https://docs.livekit.io/agents/logic/turns/)).
- Enhanced noise and background-voice cancellation are available in LiveKit Cloud ([turns](https://docs.livekit.io/agents/logic/turns/)).
- SIP trunks are tested with Twilio, Telnyx, Plivo, Exotel, and others. Features include DTMF, cold and warm transfer, and US phone numbers ([telephony](https://docs.livekit.io/agents/start/telephony/)).
- Realtime models: OpenAI GPT Realtime/GPT-Live, Gemini Live, and Grok Voice. Avatars: Anam and Tavus ([models](https://docs.livekit.io/agents/models/)).
- Testing: pytest or Vitest unit tests for messages, tool calls, and handoffs, plus multi-turn simulations ([testing](https://docs.livekit.io/agents/start/testing/)).
- Observability: transcripts, traces, metrics, and recordings on one timeline, OTel export, and PII redaction ([observability](https://docs.livekit.io/deploy/observability/)).
- Pricing: agent sessions cost $0.01/min after included minutes. HIPAA BAA and SOC 2 Type II are listed from the Scale tier ([pricing](https://livekit.com/pricing)).

### OpenAI Realtime API and Agents SDK voice

- Connects over WebRTC (browser) or WebSocket (server), with ephemeral client secrets ([Realtime guide](https://developers.openai.com/api/docs/guides/realtime)).
- `server_vad` (silence-based) and `semantic_vad` (end-of-utterance classifier with `eagerness`) ([VAD guide](https://developers.openai.com/api/docs/guides/realtime-vad)).
- SIP: incoming calls arrive by webhook, then the API can accept, reject, refer (transfer), and hang up. DTMF events are available ([SIP guide](https://developers.openai.com/api/docs/guides/realtime-sip)).
- Tools, MCP servers, and handoffs attach to a `RealtimeAgent` ([Realtime guide](https://developers.openai.com/api/docs/guides/realtime), [MCP](https://developers.openai.com/api/docs/guides/realtime-mcp)).
- Agents SDK `VoicePipeline` chains STT → agent workflow → TTS and supports handoffs ([voice quickstart](https://openai.github.io/openai-agents-python/voice/quickstart/)).

### Vapi

- Pricing is $0.05/min hosting, with model costs passed through at cost. HIPAA is a $2,000/month add-on with a BAA ([pricing](https://vapi.ai/pricing)).
- SOC 2 Type II covers all plans ([SOC](https://docs.vapi.ai/security-and-privacy/soc)).
- Other features are SIP trunking (Twilio, Telnyx, Plivo, and more), custom tools, MCP tools, a knowledge base, Squads for multi-agent handoff, simulations and evals, call recording, and Langfuse ([docs index](https://docs.vapi.ai/llms.txt)).
- Workflows are being retired in favor of Squads (date in [migration page](https://docs.vapi.ai/workflows/legacy-migration)).

### Retell AI

- Agent types are single-prompt or node-based conversation flows. Other features are a knowledge base (crawl or upload), simulation tests, A/B tests, post-call analysis, and live monitoring ([intro](https://docs.retellai.com/general/introduction)).
- Telephony is via Twilio, Telnyx, Vonage, or custom SIP. Native SDKs cover iOS, Android, React Native, and Flutter. Agent transfer and GPT-Live are supported ([docs index](https://docs.retellai.com/llms.txt)).
- Pricing is about $0.055/min voice infra plus LLM and TTS, about $0.07–0.31/min in total. Retell describes itself as SOC 2 certified and HIPAA-ready ([pricing](https://www.retellai.com/pricing)).

### ElevenLabs Agents

- ElevenLabs uses its own turn-taking model. Features are Twilio, SIP trunking, batch calls, custom LLMs, realtime models, workflows, a knowledge base, tests, experiments, and analysis ([overview](https://elevenlabs.io/docs/agents-platform/overview)).
- Tool types are client, webhook, sandboxed code, MCP, and system tools ([tools](https://elevenlabs.io/docs/eleven-agents/customization/tools)).
- SDKs cover React, Swift, Kotlin, React Native, and Unity ([overview](https://elevenlabs.io/docs/agents-platform/overview)).
- Pricing is $0.08/min plus LLM costs. A BAA is offered only on Enterprise ([pricing](https://elevenlabs.io/pricing/agents)).

### Daily (transport)

- `daily-js` handles WebRTC, recording, Deepgram transcription, and Krisp noise cancellation ([daily-js](https://docs.daily.co/guides/products/ai-toolkit)).
- Other features are SIP/PSTN dial-in, dial-out, and transfers, plus iOS, Android, React Native, and Python SDKs ([docs index](https://docs.daily.co/llms.txt)).
- HIPAA requires the paid Healthcare add-on, and Daily signs the BAA at no extra cost ([HIPAA](https://docs.daily.co/guides/privacy-and-security/hipaa)).

### TEN Framework

- The license is Apache-2.0 with additional restrictions. TEN supplies its own VAD and turn-detection models, a SIP extension, the TMAN Designer visual editor, Agora RTC or WebSocket transport, and avatars (Trulience, HeyGen, Tavus) ([repo](https://github.com/TEN-framework/ten-framework)).

### Ultravox

- Ultravox runs on an open-weight model ([fixie-ai/ultravox](https://github.com/fixie-ai/ultravox)). It supports 26 languages, tools, call stages, RAG, recordings, and webhooks ([overview](https://docs.ultravox.ai/overview)).
- Telephony: Twilio, Telnyx, Plivo, and Exotel natively, plus SIP ([telephony](https://docs.ultravox.ai/telephony/overview)).

### Bland AI

- Features are pathways (flows), SIP, bring-your-own Twilio, a knowledge base, voice cloning, a web agent SDK, and evaluations ([docs index](https://docs.bland.ai/llms.txt), [home](https://docs.bland.ai/welcome-to-bland)).
- The docs index says Bland holds SOC 2 Type II, HIPAA, GDPR, and PCI DSS certifications and supports 40+ languages ([docs index](https://docs.bland.ai/llms.txt)).

### Deepgram Voice Agent API

- One WebSocket API runs listen, think, and speak. It adds function calling, multi-agent handoff, telephony, and a browser agent SDK ([voice agent](https://developers.deepgram.com/docs/voice-agent)).

### Vocode

- Vocode is MIT-licensed. It offers inbound and outbound phone agents and many STT and TTS providers. The maintainers are "actively looking for community maintainers" ([vocode-core](https://github.com/vocodedev/vocode-core)).

### Elixir building blocks

- **Membrane WebRTC plugin**: a WebRTC Source and Sink on `ex_webrtc`. Phoenix signaling and the LiveView `Live.Capture` and `Live.Player` components are included. License Apache-2.0, version 0.26.x ([repo](https://github.com/membraneframework/membrane_webrtc_plugin)). AudioFlow does not use it yet (`mix.exs`).
- **Nx.Serving**: batching, multi-GPU partitions, and distribution over Erlang distribution by default with `distribution_weight`. Input and output can be streamed ([docs](https://nx.hexdocs.pm/Nx.Serving.html)).
- **Bumblebee**: `speech_to_text_whisper` supports streamed input with chunking, a `:stream` output mode, timestamps, and `:language` ([Bumblebee.Audio](https://bumblebee.hexdocs.pm/Bumblebee.Audio.html)).
- **Jido**: agents, actions, CloudEvents signals, directives, parent/child hierarchies, and Pods. LLM support comes from the optional `jido_ai` package. License Apache-2.0 ([repo](https://github.com/agentjido/jido)).

## 4. Gaps in AudioFlow, ranked by impact

### High

1. **No real-time network transport (WebRTC or streaming WebSocket).**
   - *Competitors:* Pipecat offers Daily, LiveKit, SmallWebRTC, and WebSocket ([services](https://docs.pipecat.ai/server/services/supported-services)). LiveKit is WebRTC-native ([intro](https://docs.livekit.io/agents/)). OpenAI Realtime offers WebRTC and WebSocket ([guide](https://developers.openai.com/api/docs/guides/realtime)).
   - *AudioFlow today:* input is a PCM file or PortAudio (`lib_media/audio_flow/input_pipeline.ex`, `lib_media/audio_flow/pcm_file_source.ex`). Output is a PortAudio sink (`lib_media/audio_flow/playback.ex`). The chat example sends Base64 PCM over LiveView `pushEvent` (`examples/chat/assets/js/audio.js`).
   - *Suggestion:* add a transport on `membrane_webrtc_plugin` (`Live.Capture` and `Live.Player`) and a raw PCM WebSocket transport.

2. **No telephony (SIP or PSTN providers).**
   - *Competitors:* all hosted platforms and LiveKit support it. Pipecat has serializers for Twilio, Telnyx, Plivo, and others ([services](https://docs.pipecat.ai/server/services/supported-services)). LiveKit has SIP trunks, DTMF, and transfer ([telephony](https://docs.livekit.io/agents/start/telephony/)).
   - *AudioFlow today:* no telephony code in `lib/`, `lib_media/`, or `README.md`.
   - *Suggestion:* first add a Twilio/Telnyx Media Streams WebSocket serializer (8 kHz μ-law ↔ 16 kHz PCM). SIP can come later.

3. **No tool/function calling during a turn.**
   - *Competitors:* LiveKit, OpenAI Realtime + MCP, Vapi, Retell, ElevenLabs (client, webhook, code, MCP), and Deepgram all support it (see §3).
   - *AudioFlow today:* `Adapters.ChatHTTP` fails with `:unsupported_tool_call` (`lib/audio_flow/adapters/chat_http.ex:169`). The README says it "does not implement … tool execution" (`README.md`). Jido is supervised but not connected to turns (`lib/audio_flow/jido.ex`).
   - *Suggestion:* parse streamed `tool_calls`, run them as Jido actions under the session, and loop the results back to the LLM. Speak a filler phrase while a tool runs.

4. **No speech-to-speech model adapter.**
   - *Competitors:* Pipecat and LiveKit support OpenAI Realtime, Gemini Live, Nova Sonic, Grok, and Ultravox ([Pipecat services](https://docs.pipecat.ai/server/services/supported-services), [LiveKit models](https://docs.livekit.io/agents/models/)).
   - *AudioFlow today:* only chained STT → LLM → TTS adapters (`lib/audio_flow/adapter.ex`, `lib/audio_flow/adapters/`).
   - *Suggestion:* add an `Adapters.OpenAIRealtime` and a Gemini Live WebSocket adapter that map to the existing transcript, text, and audio events.

5. **No echo cancellation or noise suppression on the server path.**
   - *Competitors:* Pipecat has Krisp, Koala, RNNoise, and ai-coustics ([services](https://docs.pipecat.ai/server/services/supported-services)). LiveKit Cloud has noise and background-voice cancellation ([turns](https://docs.livekit.io/agents/logic/turns/)). Daily has Krisp ([daily-js](https://docs.daily.co/guides/products/ai-toolkit)).
   - *AudioFlow today:* "Echo cancellation is not included. Speaker audio can therefore trigger the detector" (`README.md`). Only the browser example asks for `echoCancellation`/`noiseSuppression` from `getUserMedia` (`examples/chat/assets/js/audio.js:90`).
   - *Suggestion:* add an RNNoise or WebRTC-APM Membrane filter before VAD. Add a reference-signal AEC for the PortAudio path.

### Medium

6. **No semantic end-of-turn model.**
   - *Competitors:* Pipecat Smart Turn ([smart-turn](https://github.com/pipecat-ai/smart-turn)), the LiveKit turn detector ([turns](https://docs.livekit.io/agents/logic/turns/)), OpenAI `semantic_vad` ([VAD](https://developers.openai.com/api/docs/guides/realtime-vad)), and TEN Turn Detection ([repo](https://github.com/TEN-framework/ten-framework)).
   - *AudioFlow today:* Silero VAD with silence-based endpoint rules (`lib_ml/audio_flow/silero.ex`, `lib/audio_flow/voice_input.ex`).
   - *Suggestion:* Smart Turn v3 is BSD-2, ONNX, and Whisper-Tiny-based. Run it through Transmuter/Nx after Silero detects silence.

7. **No observability standard (OpenTelemetry or `:telemetry`).**
   - *Competitors:* Pipecat OTel spans per turn and service ([OTel](https://docs.pipecat.ai/server/utilities/opentelemetry)). LiveKit insights, OTel, and recordings ([observability](https://docs.livekit.io/deploy/observability/)).
   - *AudioFlow today:* terminal events carry timing metrics, and the benchmark writes CSV (`README.md`, `lib/audio_flow/benchmark.ex`). No `:telemetry` calls were found in `lib/`.
   - *Suggestion:* emit `:telemetry` spans per session, turn, and stage, and document an `opentelemetry_telemetry` bridge.

8. **Interruption is basic.** The session is busy during a turn, and there is no resume after a false interruption and no history truncation to what the user heard.
   - *Competitors:* LiveKit has adaptive interruption, `min_words`, false-interruption resume, and truncation to heard speech ([turns](https://docs.livekit.io/agents/logic/turns/)).
   - *AudioFlow today:* `cancel/1` plus flush. Further input returns `{:error, :busy}`. Cancelled turns leave previous history intact (`README.md`, `lib/audio_flow/history.ex`).
   - *Suggestion:* record played-out audio offsets in `Playback`, and add the heard part of the reply to history on cancel.

9. **No client SDKs or client protocol.**
   - *Competitors:* Pipecat has six SDKs on the open RTVI protocol ([client](https://docs.pipecat.ai/client/introduction)). Retell has iOS, Android, React Native, and Flutter ([docs index](https://docs.retellai.com/llms.txt)). ElevenLabs has React, Swift, Kotlin, React Native, and Unity ([overview](https://elevenlabs.io/docs/agents-platform/overview)).
   - *AudioFlow today:* only the LiveView example (`examples/chat/README.md`).
   - *Suggestion:* use RTVI on the server side so existing Pipecat client SDKs can connect, instead of writing new SDKs.

10. **Graphs are static DAGs, with no conversation state machine or multi-agent handoff.**
    - *Competitors:* Pipecat Flows ([repo](https://github.com/pipecat-ai/pipecat-flows)), LiveKit tasks, workflows, and handoff ([intro](https://docs.livekit.io/agents/)), Vapi Squads ([docs index](https://docs.vapi.ai/llms.txt)), Retell flows and agent transfer, and Agents SDK handoffs ([voice](https://openai.github.io/openai-agents-python/voice/quickstart/)).
    - *AudioFlow today:* a graph needs no cycles and runs as one session (`ui/README.md`, `lib/audio_flow/graph.ex`).
    - *Suggestion:* add flow nodes (state, transition on tool result or intent) on top of Jido FSM strategies. Handoff would swap the prompt and tools but keep the session.

11. **Narrow provider breadth.**
    - *Competitors:* Pipecat lists about 35 STT, 30 LLM, and 60 TTS services ([services](https://docs.pipecat.ai/server/services/supported-services)).
    - *AudioFlow today:* local Nx models plus one OpenAI-compatible chat adapter. There are no remote STT/TTS adapters (`lib/audio_flow/adapters/`, `README.md`).
    - *Suggestion:* add streaming Deepgram STT and Cartesia/ElevenLabs TTS adapters first, because they cover most production stacks.

12. **No eval, simulation, or regression testing for agent behavior.**
    - *Competitors:* LiveKit unit tests and simulations ([testing](https://docs.livekit.io/agents/start/testing/)), Vapi simulations and evals, Retell simulation tests and A/B tests (see §3).
    - *AudioFlow today:* latency benchmark and model checks (`site/src/content/docs/docs/validation/*.md`). MCP `run_graph` runs one text turn (`ui/README.md`).
    - *Suggestion:* add an ExUnit helper for scripted multi-turn text runs with assertions on replies and tool calls. A later step can use an LLM-simulated user.

### Low

13. **Multilingual TTS.** Kokoro voices are limited to en-us/en-gb (`lib_ml/audio_flow/graph/models.ex:187`). Whisper supports `:language` ([Bumblebee.Audio](https://bumblebee.hexdocs.pm/Bumblebee.Audio.html)). Competitors cover 26–70+ languages (§3). *Suggestion:* expose the Whisper language option, and add multilingual Kokoro voices or MMS VITS languages.
14. **No knowledge base/RAG node.** AudioFlow has text embeddings but no retrieval (`ui/README.md`). Vapi, Retell, ElevenLabs, Ultravox, and Bland have knowledge bases (§3). *Suggestion:* add a `rag.retrieve` graph node over embeddings and pgvector.
15. **No recordings or transcript store.** LiveKit Egress ([observability](https://docs.livekit.io/deploy/observability/)) and Vapi call recording ([docs index](https://docs.vapi.ai/llms.txt)) provide them. AudioFlow keeps artifacts only for validation (`README.md`, `AUDIOFLOW_PIPELINE_ARTIFACT_DIR`). *Suggestion:* add an optional per-session recorder sink.
16. **No avatars.** Pipecat and LiveKit integrate Tavus, HeyGen, Simli, and Anam (§3). *Suggestion:* defer this until a WebRTC video sink exists.
17. **Compliance features (PII redaction, retention).** LiveKit offers PII redaction ([observability](https://docs.livekit.io/deploy/observability/)). AudioFlow has no redaction or retention controls. *Suggestion:* add a transcript-redaction hook. (AudioFlow now has an Apache-2.0 `LICENSE` file.)

## 5. AudioFlow differentiators

- **Full in-process native inference on the BEAM.** Silero, Whisper, Qwen3, Kokoro, VITS, CLIP, BLIP, and embeddings share Nx servings without Python or cloud (`README.md`, `ui/README.md`). Pipecat's smallest local path needs Python processes. The local-model section of its services list has Kokoro and Piper, but they run in Python ([services](https://docs.pipecat.ai/server/services/supported-services)).
- **BEAM-distributed inference workers.** Routes and workers run across nodes, and node loss and cancellation reach remote tasks (`lib/audio_flow/worker.ex`, `lib/audio_flow/router.ex`). This builds on Nx.Serving distribution by default ([Nx.Serving](https://nx.hexdocs.pm/Nx.Serving.html)). Competitors scale with containers and Kubernetes instead ([Pipecat Cloud](https://docs.pipecat.ai/deployment/pipecat-cloud/introduction), [LiveKit](https://docs.livekit.io/agents/)).
- **OTP supervision per session.** Each session is supervised, and there is explicit busy and cancel semantics plus bounded output queues (`lib/audio_flow/session.ex`, `README.md`).
- **Controlled, reproducible benchmark against Pipecat.** It uses the same models and records hashes, p50/p95, and capacity rules (`scripts/COMPARISON.md`, `site/src/content/docs/docs/validation/pipecat-comparison.md`). No competitor publishes a comparison like this.
- **Typed graph editor with an MCP endpoint for coding agents.** Coding agents can list, save, validate, and run graphs (`ui/README.md`). Vapi, Retell, and ElevenLabs expose MCP to manage agents ([Vapi](https://docs.vapi.ai/llms.txt), [Retell](https://docs.retellai.com/llms.txt), [ElevenLabs](https://elevenlabs.io/docs/agents-platform/overview)). AudioFlow's version is local, typed, and self-hosted.
- **Video frame input as a first-class turn type** with demand-driven Membrane decoding and image captioning (`lib_media/audio_flow/video.ex`, `site/src/content/docs/docs/guides/video.md`). Most hosted voice platforms list no vision input (§2).
- **No per-minute platform fee.** AudioFlow is self-hosted. Vapi charges $0.05/min ([pricing](https://vapi.ai/pricing)), ElevenLabs $0.08/min ([pricing](https://elevenlabs.io/pricing/agents)), and LiveKit $0.01/agent-min ([pricing](https://livekit.com/pricing)).

## 6. Claims I could not verify from a primary source

- **Pipecat Flows visual editor** (flows.pipecat.ai): the archived repo links to it but does not describe it. *Unverified.*
- **Pipecat built-in eval/simulation tooling**: not found on the pages read. *Unverified.*
- **Pipecat Cloud HIPAA/SOC 2**: not on the Cloud intro page. Daily's HIPAA add-on may apply. *Unverified.*
- **Ultravox pricing, WebRTC/WebSocket transport details, SDK languages**: not on the pages read. *Unverified.*
- **Bland and Deepgram Voice Agent per-minute pricing**: pages not read or no price shown. *Unverified.*
- **Bland compliance list** (SOC 2 II, HIPAA, GDPR, PCI): seen only in an index summary, not on a dedicated compliance page. *Partly verified.*
- **ElevenLabs language count**: the overview gives both "31 languages" and "70+ languages". *Inconsistent in source.*
- **ElevenLabs agent-to-agent transfer**: system tools are named but not listed on the tools page. *Unverified.*
- **Retell and ElevenLabs PII redaction**: no dedicated page found. Retell has privacy and retention controls only. *Unverified.*
- **TEN extension languages** (C++/Go/Python/Node): not listed on the README read. *Unverified.*
- **Gemini Live native-audio model names and automatic activity detection settings**: not on the page read. *Unverified.*
- **Vocode maintenance status**: the README asks for maintainers. The last commit date was not visible. *Unverified.*
- **OpenAI Realtime input noise reduction**: not described in the VAD guide. *Unverified.*
