# AudioFlow chat

A local LiveView chat over one AudioFlow session per browser tab. Type a
message, or record one with the microphone. The reply text streams into the
conversation, the reply audio plays as it arrives, and each reply keeps an
audio player for replay. The UI uses [live_shadcn](https://live-shadcn-storybook.fly.dev/)
and its AI Elements components.

## Run

Requirements: the tool versions in the repository `mise.toml`, Node.js 20 or
later, and `espeak-ng` for Kokoro (`brew install espeak-ng` on macOS).

```sh
cd examples/chat
mix setup
mix phx.server
```

Open http://localhost:4000. Set `PORT` to use another port, and
`LOG_LEVEL=debug` to log each LiveView event.

## Models

The chat loads its models once at startup through `examples/models.exs`.
The first start downloads them to the Bumblebee cache:

| Stage | Default model |
| --- | --- |
| Speech recognition | `openai/whisper-tiny` |
| Reply | `Qwen/Qwen3-0.6B`, with conversation history |
| Speech | Kokoro 82M, voice `af_heart` |

The environment variables of `examples/models.exs` change these defaults. For
example, `AUDIOFLOW_VOICE=am_adam` selects another Kokoro voice. To use a chat
server for replies, set `AUDIOFLOW_LLM_ENGINE=http`, `AUDIOFLOW_CHAT_ENDPOINT`,
and `AUDIOFLOW_LLM`, the model ID of the server. Set `AUDIOFLOW_CHAT_API_KEY`
when the server requires a key.

The first turn compiles the models. It took about 8 s to the first reply audio
on an Apple Silicon CPU. A later turn took about 5 s.

## Audio

The browser records mono audio, converts it to 16 kHz s16le PCM, and sends one
utterance when you stop the recording. A recording stops after 30 seconds.
A new recording, or the Stop button, cancels the current reply and stops
playback. Microphone access requires `localhost` or HTTPS.

## Components

`live_base`, `live_shadcn`, and `live_ai_elements` come from a pinned
live_shadcn commit. Set `LIVE_SHADCN_PATH` to a local checkout to use it
instead. `button` and `badge` were copied with `mix ui.add`; `mix ui.sync`
reports upstream changes. The shadcn style sheets in `assets/css/upstream` are
pinned to the commit in live_shadcn's `registry/UPSTREAM.json`.
