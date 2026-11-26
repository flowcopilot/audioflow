# AudioFlow

AudioFlow is an Elixir voice, image, and video agent runtime. Each conversation uses an OTP
session. Sessions share model services through an engine-independent adapter.
Optional bounded history keeps successful conversation turns in each session.

This implements the session runtime, model routing, distributed inference workers,
native Silero voice detection, Whisper and text-generation adapters, Kokoro and
VITS speech synthesis, and Membrane audio and video input.
The native media path has a recorded-speech integration
check and a controlled Pipecat comparison. Output interruption is measured at
the software transport. Acoustic interruption needs a device loopback check.
HTTP language inference can use a compatible local server or cloud endpoint.
Text embeddings, CLIP image embeddings, and BLIP image captions use shared
native model services. Their model checks use independent PyTorch references.
The core runs without model downloads. The demo produces fixed text and silent
PCM. Use the model examples for real inference.

## Run

Use the tool versions in `mise.toml`, or Elixir 1.18 or later with a compatible
OTP version.

```sh
mix deps.get
mix test
mix run examples/demo.exs
mix audio_flow.bench --runs 20 --concurrency 4
```

The core needs no model downloads. It resamples audio and codes G.711 with
FFmpeg through two Membrane plugins, so the first build needs a C compiler and
downloads prebuilt FFmpeg libraries. Optional parts are enabled with environment
variables:

| Variable | Adds | Source directory |
| --- | --- | --- |
| none | Sessions, history, routing, HTTP inference, remote providers | `lib` |
| `AUDIOFLOW_ML=1` | Bumblebee, EXLA, Transmuter models | `lib_ml` |
| `AUDIOFLOW_MEDIA=1` | Membrane audio and video | `lib_media` |
| `AUDIOFLOW_WEBRTC=1` | ExWebRTC media output and the PCM bridge | `lib_webrtc` |
| `AUDIOFLOW_SFU=1` | Agents as SFU room participants, and durable calls | `lib_sfu` |

Core, ML, media, and combined ML/media builds use separate `_build` directories.
Changing a feature flag does not remove modules used by another build profile.

To run an example with real inference, enable the model code:

```sh
AUDIOFLOW_ML=1 mix deps.get
AUDIOFLOW_ML=1 mix run examples/kokoro.exs "Hello from AudioFlow." output.wav
```

## Documentation

The website and documentation are at <https://flowcopilot.github.io/audioflow/>.
Their source is in [site](site/README.md).

Start here:

- [Introduction](https://flowcopilot.github.io/audioflow/docs/): what AudioFlow is, and how its parts fit together.
- [Quickstart](https://flowcopilot.github.io/audioflow/docs/quickstart/): running the tests, the demo session, and real models.
- [Chat example](https://flowcopilot.github.io/audioflow/docs/chat-example/): a LiveView voice and text chat.

Guides:

- [Sessions](https://flowcopilot.github.io/audioflow/docs/guides/sessions/): turns, events, cancellation, and limits for one conversation.
- [Transcription](https://flowcopilot.github.io/audioflow/docs/guides/transcription/): speech-to-text adapters, transcription sessions, and long recordings.
- [Conversation history](https://flowcopilot.github.io/audioflow/docs/guides/history/): keeping earlier turns in the prompt, with limits.
- [Local models](https://flowcopilot.github.io/audioflow/docs/guides/local-models/): Whisper, Qwen3, Kokoro, and VITS as shared Nx services.
- [HTTP language models](https://flowcopilot.github.io/audioflow/docs/guides/http-inference/): streaming replies from llama.cpp or any ReqLLM provider.
- [Images and embeddings](https://flowcopilot.github.io/audioflow/docs/guides/images/): CLIP and BERT embeddings, BLIP captions, and image turns.
- [Video input](https://flowcopilot.github.io/audioflow/docs/guides/video/): reading H.264 frames from MP4 files or a camera source.
- [Routing and workers](https://flowcopilot.github.io/audioflow/docs/guides/routing/): bounded workers, model routes, and inference on other nodes.
- [Membrane input](https://flowcopilot.github.io/audioflow/docs/guides/membrane-input/): voice detection, endpointing, and resampling for live audio.
- [Output transport](https://flowcopilot.github.io/audioflow/docs/guides/output/): playing reply audio, and flushing it when the user interrupts.
- [WebSocket transport](https://flowcopilot.github.io/audioflow/docs/guides/websocket/): streaming PCM and events between a browser and a session.
- [Telemetry](https://flowcopilot.github.io/audioflow/docs/guides/telemetry/): session, turn, and stage spans, with an OpenTelemetry bridge.
- [Hot upgrades](https://flowcopilot.github.io/audioflow/docs/guides/hot-upgrades/): upgrading a running node with Castle without dropping calls.

Features:

- [Remote speech providers](https://flowcopilot.github.io/audioflow/docs/features/providers/): Deepgram, Cartesia, ElevenLabs, Fish Audio, OpenAI Realtime, and Gemini Live adapters.
- [Network transports](https://flowcopilot.github.io/audioflow/docs/features/transports/): raw PCM WebSocket, Twilio and Telnyx telephony, and the Pipecat RTVI client.
- [AudioFlow SFU](https://flowcopilot.github.io/audioflow/docs/features/sfu/): a BEAM SFU with LiveKit client SDK support, telephony and hot upgrades.
- [Durable calls](https://flowcopilot.github.io/audioflow/docs/features/durable-calls/): calls that stay connected when an agent node is deployed, restarted or lost.
- [Input processing](https://flowcopilot.github.io/audioflow/docs/features/input-processing/): server-side denoising, echo cancellation, and Smart Turn endpoints.
- [WebRTC and avatars](https://flowcopilot.github.io/audioflow/docs/features/webrtc-avatars/): optional encoded WebRTC media and LiveAvatar publishing.
- [Conversations and retrieval](https://flowcopilot.github.io/audioflow/docs/features/conversation-and-retrieval/): conversation states, Jido handoffs, and pgvector retrieval graphs.
- [Conversation evaluations](https://flowcopilot.github.io/audioflow/docs/features/conversation-evaluations/): scripted regression tests over real session turns.
- [Interruption](https://flowcopilot.github.io/audioflow/docs/features/interruption/): playback acknowledgements, provisional interruption, and heard reply history.
- [Speech languages](https://flowcopilot.github.io/audioflow/docs/features/model-languages/): language choices for native Whisper and MMS VITS nodes.
- [Recording and privacy](https://flowcopilot.github.io/audioflow/docs/features/recording-and-privacy/): opt-in recordings and transcript redaction.

Validation:

- [Model checks](https://flowcopilot.github.io/audioflow/docs/validation/model-checks/): how model output is compared with independent references.
- [Benchmarks](https://flowcopilot.github.io/audioflow/docs/validation/benchmarks/): time to first transcript, text, and audio per turn.
- [Pipecat comparison](https://flowcopilot.github.io/audioflow/docs/validation/pipecat-comparison/): AudioFlow and Pipecat over the same model services.

## Examples and tools

- [examples/](examples/): runnable scripts. Most need `AUDIOFLOW_ML=1` or `AUDIOFLOW_MEDIA=1`.
- [examples/chat](examples/chat/README.md): browser voice and text chat, with always-on OpenAI Realtime and Moshi modes.
- [examples/network](examples/network/README.md): optional WebRTC audio and video output, and the PCM Session bridge.
- [examples/durable-call](examples/durable-call/README.md): a browser call that survives `kill -9` of the agent node.
- [sfu](sfu/README.md): the AudioFlow SFU, a separate Mix project and release.
- [releases](releases/README.md): hot-upgradable releases, and calls across the SFU and agent nodes.
- [examples/avatar](examples/avatar/README.md): standalone viewer for LiveAvatar publications. It subscribes only when configured with an account.
- [ui](ui/README.md): local dashboard with a canvas editor for node graphs, and an MCP endpoint for coding agents. A session runs an `AudioFlow.Graph` with the `:graph` option.
- [scripts/COMPARISON.md](scripts/COMPARISON.md): the method for the AudioFlow and Pipecat comparison.
- [validation](validation/): saved reports and data, including the [native CPU run](validation/native-cpu.html), the [conversation checks](validation/conversation-smoke.json), and the [Pipecat comparison](validation/comparison.html).

## License

AudioFlow is licensed under the [Apache License 2.0](LICENSE).
