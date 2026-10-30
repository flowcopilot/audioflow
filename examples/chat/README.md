# AudioFlow chat

A local LiveView chat over one AudioFlow session per browser tab. Type a
message, or record one with the microphone. While you record, the user message
shows a live transcript. The reply text streams into the conversation, the
reply audio plays as it arrives, and each reply keeps an audio player for
replay. The UI uses [live_shadcn](https://live-shadcn-storybook.fly.dev/) and
its AI Elements components.

The models run on the Apple Silicon GPU through MLX. This example therefore
needs an Apple Silicon Mac with macOS 26.2 or later.

## Run

Requirements: the tool versions in the repository `mise.toml`, Node.js 20 or
later, [uv](https://docs.astral.sh/uv/) for model downloads and Qwen3-ASR, and
`espeak-ng` for Kokoro (`brew install espeak-ng`).

```sh
cd examples/chat
mix setup
mix phx.server
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
the reply stage are stored in the user cache directory, under `audioflow_chat`.

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
