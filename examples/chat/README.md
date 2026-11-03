# AudioFlow chat

A local LiveView chat over one AudioFlow session per browser tab. Type a
message, or record one with the microphone. While you record, the user message
shows a live transcript. The reply text streams into the conversation, the
reply audio plays as it arrives, and each reply keeps an audio player for
replay. The UI uses [live_shadcn](https://live-shadcn-storybook.fly.dev/) and
its AI Elements components.

The native profile runs models on Apple Silicon through MLX (macOS 26.2+).
Linux defaults to a credential-free synthetic demo. Remote providers work in
the demo build too: choose a provider in the page after setting server variables.
No provider or native model verification is implied by a successful demo.

## Run on Linux / without model downloads

```sh
cd examples/chat
export CHAT_PROFILE=demo
mix setup
mix phx.server
# regression tests (no credentials):
mix test
```

Demo STT returns a fixed “Hello”, replies echo the input and output PCM is silent.
It tests session wiring, not recognition or synthesis. No EMLX, EXLA, Bumblebee
or model downloads are needed. Use the same profile for all Mix commands.

## Run native models on Apple Silicon

The repository `mise.toml` pins Erlang, Elixir, Node.js, and
[uv](https://docs.astral.sh/uv/). uv runs the separate Qwen3-ASR Python
process; reply model downloads use Elixir's `hf_hub` and need no Python or
`uvx`. Kokoro also needs `espeak-ng`, which mise does not provide.

```sh
mise install
brew install espeak-ng
cd examples/chat
CHAT_PROFILE=native mix setup
CHAT_PROFILE=native mix phx.server
```

Open http://localhost:4000. Set `PORT` to use another port, and
`LOG_LEVEL=debug` to log each LiveView event.

## Models

Select the models in the page. The first selection of a model downloads it.
A switch applies to the next turn and keeps the conversation history. One
model per stage stays loaded.

| Stage | Models | Runtime |
| --- | --- | --- |
| Speech recognition | Whisper tiny, small, large v3 turbo | Bumblebee on the EMLX GPU backend |
| Speech recognition | Qwen3-ASR 0.6B and 1.7B, 8-bit | mlx-audio in a Python process managed by uv |
| Reply | Qwen3 0.6B, 1.7B, 4B, and 8B, 4-bit | native EMLXAxon Qwen3 generation |
| Speech | Kokoro 82M, four voices | Transmuter on the EMLX GPU backend |

The page shows an estimate of the loaded model weights. The largest
combination is about 8.2 GB. Compiled kernels and caches use more memory.
The defaults are Whisper small, Qwen3 1.7B, and the `af_heart` voice. Set
`CHAT_STT`, `CHAT_LLM`, or `CHAT_VOICE` to a model ID from `lib/chat/catalog.ex`
to change the startup selection.

Measured on an Apple M5 with 24 GB of memory, after the first turn:

| Models | First text | First audio |
| --- | ---: | ---: |
| Whisper small, Qwen3 1.7B | 0.9 s | 1.5 s |
| Qwen3-ASR 0.6B, Qwen3 0.6B | 0.3 s | 0.8 s |

The first turn after a switch compiles the new model. It took up to 6 s to the
first audio. Bumblebee has no Qwen3-ASR model, so Qwen3-ASR runs outside the
BEAM. Its log is `$TMPDIR/audioflow-chat-qwen3-asr.log`. Model checkpoints for
the reply stage use hf_hub's cache, by default
`~/.cache/huggingface/hub/models--OWNER--REPO/snapshots/REVISION`.
The pinned revisions in `Chat.Catalog` are passed unchanged, and this directory
is passed directly to EMLXAxon's checkpoint loader. Old `audioflow_chat` CLI
downloads are not reused or deleted; the first selection downloads a new copy.

Reply downloads use `hf_hub ~> 0.3.1` (locked to 0.3.1), compatible with the
chat's Elixir 1.18+ and Req 0.7 dependencies. It is included in native builds
and demo tests, not demo development/production builds. To change its cache,
set `config :hf_hub, :cache_dir, "/absolute/cache/path"` before downloading.
Version 0.3.1 documents a per-call `:cache_dir` option but its filesystem code
uses application configuration; the wrapper does not mutate that global setting.

Every selection checks the repository listing, even with a cached config.
hf_hub reuses completed files, writes downloads to `.incomplete` files and
renames them only after success. A failed snapshot raises with repository,
revision and failure details; retrying fetches missing files. This requires
Hub metadata access even for a fully cached snapshot. It does not verify
existing nonempty files against remote checksums. An abrupt VM/OS crash can
leave hf_hub lock files under the cache's `locks/` directory; remove stale
locks only after ensuring no downloader is running.

The behavior above was checked against the
[0.3.1 download source](https://github.com/North-Shore-AI/hf_hub_ex/blob/v0.3.1/lib/hf_hub/download.ex),
[HTTP source](https://github.com/North-Shore-AI/hf_hub_ex/blob/v0.3.1/lib/hf_hub/http.ex)
and [filesystem source](https://github.com/North-Shore-AI/hf_hub_ex/blob/v0.3.1/lib/hf_hub/fs.ex).
Run the real library against a local HTTP fixture, without Apple hardware,
credentials or model downloads:

```sh
CHAT_PROFILE=demo MIX_ENV=test mix deps.get
CHAT_PROFILE=demo mix test test/hf_test.exs
```

EMLX is pinned to a commit on its main branch. Release 0.5.0 cannot compile
Whisper, which has non-finite constants. `Chat.EMLXCompiler` removes the
`:batch_keys` option that `Nx.Serving` passes and EMLX rejects.

## Audio

The browser records mono audio and converts it to 16 kHz s16le PCM. It sends
new audio every 0.5 seconds. The current speech recognition model transcribes
the recording so far, one request at a time, and the user message shows that
text. When you stop recording, the complete audio is one session turn, and its
transcript replaces the live text. A recording stops after 30 seconds.

A new recording, a typed message, or the Stop button cancels the current reply
and stops playback. Microphone access requires `localhost` or HTTPS.

## Components

`live_base`, `live_shadcn`, and `live_ai_elements` come from a pinned
live_shadcn commit. Set `LIVE_SHADCN_PATH` to a local checkout to use it
instead. `button`, `badge`, `native-select`, and `spinner` were copied with `mix ui.add`; `mix ui.sync`
reports upstream changes. The shadcn style sheets in `assets/css/upstream` are
pinned to the commit in live_shadcn's `registry/UPSTREAM.json`.

## Remote providers and per-tab controls

The pipeline form applies settings by starting a **new chat**; it never silently
replays or discards history during a turn. Stop recording/generation first.
Native model selections remain shared across tabs, as before. Remote pipeline
settings are per tab. Browser events contain selection IDs and PCM, never keys.
Export credentials in the server shell before `mix phx.server`:

| Selection | Required server variables | Optional variables / controls |
| --- | --- | --- |
| Remote chain | `DEEPGRAM_API_KEY`, `CHAT_HTTP_ENDPOINT` (full chat-completions URL), `CHAT_HTTP_MODEL` | `DEEPGRAM_MODEL` (default nova-3), `CHAT_HTTP_API_KEY`; language en/es/fr/de/ro applies to STT and TTS |
| ElevenLabs TTS in chain | `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID` | `ELEVENLABS_MODEL` (default eleven_multilingual_v2) |
| Cartesia TTS in chain | `CARTESIA_API_KEY`, `CARTESIA_VOICE_ID` | `CARTESIA_MODEL` (default sonic-3.6); API version 2026-08-14 |
| OpenAI speech-to-speech | `OPENAI_API_KEY`, `OPENAI_REALTIME_MODEL` | Page voice marin/cedar; input/output 24 kHz |
| Gemini speech-to-speech | `GEMINI_API_KEY`, `GEMINI_LIVE_MODEL` (include models/ prefix) | Provider default voice/language; input 16 kHz, output 24 kHz |

Missing variables produce a visible error and keep the existing chat active.
Provider account/model/voice availability must be checked with your account.
See [provider contracts](../../docs/providers.md). The chained pipeline supports
text and microphone messages with text history. Speech-to-speech accepts only
committed microphone utterances, opens a fresh provider connection each turn,
and has **no history replay**. The language control applies only to the remote
chain; the OpenAI voice control only to OpenAI. Local voices use Kokoro's control.
The browser actually converts microphone samples to the selected rate using a
box filter; it rejects capture below that rate. This is basic speech conversion,
not a high-quality resampler. Only local STT provides partial transcriptions;
remote STT runs once on the committed utterance. Capture is bounded to 30 seconds.
Browser echoCancellation/noiseSuppression requests do not establish implemented
or verified acoustic echo cancellation in AudioFlow.

## Playback, timing, and recording privacy

The AudioContext clock acknowledges only elapsed scheduled PCM, every 100 ms
and on flush. Suspended contexts do not advance; queued buffers are not counted.
A token rejects acknowledgements from earlier turns. Stop/new input flushes
playback even after generation has finished. Cancellation conservatively keeps
only complete aligned chained speech chunks covered by acknowledgements;
it can undercount by one reporting interval. Speech-to-speech deltas have no
proven text/audio alignment; no heard-text history or native provider truncation
is claimed. Replay players do not modify conversation history. First-text,
first-audio, total generation time and acknowledged playback are separate values;
they do not measure acoustic latency.

Recording is off by default. Enable between turns to persist bounded JSON event
metadata with **all text replaced by `[REDACTED]`** and no audio. It deliberately
does not attempt selective PII detection. Controls list, download and delete the
current tab's artifacts. Disable deletes that tab's store. Bounds: 1,024 events,
128 KiB buffered per turn, 256 KiB per artifact, 20 artifacts and one hour age;
retention runs every minute and on access. A failed/oversized recording does not
stop inference. Stores are private temporary directories (0700, files 0600),
deleted on normal disconnect; abrupt process/OS failure can leave a directory
under `$TMPDIR/audioflow-chat-*` requiring operator cleanup. This localhost
example does not implement durable user authentication, backup erasure or a
production recording service. In-memory conversation text and WAV replay remain
until New chat/disconnect, independently of recording consent. Avoid debug event
logging with sensitive data; text is filtered from Phoenix event logs.

## Standalone transports

Use the [official Pipecat SDK RTVI client](../rtvi-client) for the standalone
custom transport with typed input and audio output; follow its README for the
server command, npm setup and client connection. Use
[`telephony-loopback.exs`](../telephony-loopback.exs) for the credential-free paced
telephony/Telnyx reordering exercise (`MIX_ENV=test mix run examples/telephony-loopback.exs`
from the repository root). These transports are separate runnable examples,
not modes of this microphone chat. They arrive on the parent integration branch
via PR #35. Navigation in the chat links to that branch's source/setup.

The [standalone network publisher](../network/README.md) runs actual encoded
PCMU/VP8 two-peer negotiation with `AUDIOFLOW_WEBRTC=1 mix run
examples/network/publish.exs` (run `AUDIOFLOW_WEBRTC=1 mix deps.get` first;
OpenSSL development headers/ABI required). It is **not a Session PCM bridge**.
For finite LiveAvatar LITE utterances, export `LIVEAVATAR_API_KEY` and
`LIVEAVATAR_AVATAR_ID` on the server, then run `mix run
examples/network/publish.exs --avatar speech-24k-mono-s16le.pcm` with <=10 seconds
of exactly 24 kHz mono PCM. Follow that README for authenticated LiveKit viewing,
provider-track playback and remote cleanup requirements. HTTP/WebSocket fixture
tests do not establish actual provider-generated video or lip-sync. Actual
local peer negotiation, when tested in that example, is distinct from fixtures;
this chat change does not claim to have run it.

For the standalone RTVI demo: from the repo root run `MIX_ENV=test mix run
--no-halt examples/rtvi-client/server.exs`; in `examples/rtvi-client` run
`npm ci && npm run sample` and enter the printed endpoint. Its custom transport
supports typed input/audio output, not microphone or camera tracks.

Chat validation commands:

```sh
cd examples/chat
CHAT_PROFILE=demo mix test
node --test assets/test/audio.test.js
CHAT_PROFILE=demo mix assets.build
```

The JS test uses a simulated AudioContext clock, not a browser speaker.

Implementation validation on Linux (synthetic/local fixtures only): 7 chat
ExUnit tests, 1 simulated AudioContext test, and 51 relevant core tests passed;
Tailwind and Rolldown asset builds passed. Core command from the repository root
(reuses the fetched chat dependencies/build cache):

```sh
MIX_DEPS_PATH=examples/chat/deps MIX_BUILD_PATH=examples/chat/_build/test \
  mix test test/session_test.exs test/session_speech_test.exs \
  test/session_history_test.exs test/recording_test.exs \
  test/recording_runtime_test.exs test/playout_test.exs test/remote_providers_test.exs
```

This validates server/UI events, recording cleanup/privacy/bounds, cancellation,
acknowledgements and local protocol fixtures. It does not verify Apple models,
provider credentials, browser capture/speaker behavior or actual WebRTC peer
negotiation. `npm install` reported 6 dependency audit findings (2 low, 4 moderate);
no breaking dependency upgrades were made as part of this feature.

### Provisional interruption / real browser pause

The chat's **Pause / test interruption (10 s)** control requests a provisional
interruption. **Resume false interruption** continues the same turn, worker,
queued speech and speech checkpoints. **Confirm / Stop**, the 10-second candidate
deadline, the original turn timeout, or an endpoint failure cancels and flushes.
Resume must be acknowledged before the candidate deadline too. This is an
explicit manual test control, not an automatic microphone/VAD classifier.

Chat opts into `AudioFlow.PausableOutput` through `Chat.Output`. Web Audio
`suspend()`/`resume()` operations are serialized and acknowledged only after
their promises resolve, with turn and candidate tokens. A false candidate does
not commit, truncate or otherwise change history. Confirmation uses the existing
heard-prefix policy (complete text chunks covered by rendered-PCM progress).
Completed generation with queued browser audio can also be paused/resumed.

The Session retains at most one deferred emit, backpressuring the worker rather
than collecting generated speech in an unbounded pause queue. Its original
per-turn timeout, byte and event limits remain effective. Chat has a hard total
16 MiB payload limit and 4096 events per turn; its browser schedules that finite
PCM queue, rather than implementing a sliding latency window. A paused adapter
must tolerate blocked emits; upstream providers may still buffer or time out.

Playback progress comes from elapsed segments on the AudioContext clock, which
freezes during suspension. Future scheduled segments contribute zero. This is
browser rendering progress, **not proof of physical acoustic delivery**; device
latency, muting and operating-system buffers cannot be measured here. The demo
produces silence; use local or remote TTS to hear continuity. Pause affects the
streamed Web Audio endpoint, not the separate WAV replay element.

Only this browser endpoint implements the new contract. Native Playback,
telephony, WebRTC and other legacy outputs have not gained device pause support:
Session returns `{:error, :unsupported}` for outputs without both control
callbacks. `Output.interrupt/3` retains its older transcript-filter/cancel
behavior. No provider-side pause, automatic VAD integration, or universal
endpoint support is claimed.
