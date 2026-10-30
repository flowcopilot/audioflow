# AudioFlow chat

A local LiveView chat over one AudioFlow session per browser tab. Type a
message, or record one with the microphone. The reply text streams into the
conversation, the reply audio plays as it arrives, and each reply keeps an
audio player for replay. The UI uses [live_shadcn](https://live-shadcn-storybook.fly.dev/)
and its AI Elements components.

## Run

Requirements: the tool versions in the repository `mise.toml`, and Node.js 20
or later.

```sh
cd examples/chat
mix setup
mix phx.server
```

Open http://localhost:4000. Set `PORT` to use another port.

## Engines

The engine is selected at startup. The badge in the page header shows it.

| Environment | STT | LLM | TTS |
| --- | --- | --- | --- |
| none | fixed transcript | echo | 0.2 s tone |
| `AUDIOFLOW_CHAT_ENDPOINT`, `AUDIOFLOW_LLM` | fixed transcript | HTTP chat server | 0.2 s tone |
| `AUDIOFLOW_ML=1`, `AUDIOFLOW_LLM` | Whisper | native model or HTTP | Kokoro or VITS |

The default mode downloads no models. It checks the text and audio paths only.
For real speech, compile with `AUDIOFLOW_ML=1` and set the variables that
`examples/models.exs` reads:

```sh
AUDIOFLOW_ML=1 mix deps.get
AUDIOFLOW_ML=1 AUDIOFLOW_HISTORY=1 AUDIOFLOW_LLM=Qwen/Qwen3-0.6B mix phx.server
```

Kokoro needs `espeak-ng`. Set `AUDIOFLOW_CHAT_API_KEY` when the HTTP server
requires a key.

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
