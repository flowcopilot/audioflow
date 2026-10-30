---
title: Chat example
description: A LiveView voice and text chat that runs on the Apple GPU.
---

`examples/chat` is a local LiveView chat over one AudioFlow session per browser
tab. Type a message, or record one with the microphone. While you record, the
user message shows a live transcript. The reply text streams into the
conversation, and the reply audio plays as it arrives.

The models run on the Apple Silicon GPU through MLX. This example needs an
Apple Silicon Mac with macOS 26.2 or later.

## Run

The repository `mise.toml` pins Erlang, Elixir, Node.js, and uv. Kokoro also
needs `espeak-ng`, which mise does not provide.

```sh
mise install
brew install espeak-ng
cd examples/chat
mix setup
mix phx.server
```

Open `http://localhost:4000`. Set `PORT` to use another port, and
`LOG_LEVEL=debug` to log each LiveView event.

## Models

Select the models in the page. The first selection of a model downloads it.
A switch applies to the next turn and keeps the conversation history.

| Stage | Models | Runtime |
| --- | --- | --- |
| Speech recognition | Whisper tiny, small, large v3 turbo | Bumblebee on the EMLX GPU backend |
| Speech recognition | Qwen3-ASR 0.6B and 1.7B, 8-bit | mlx-audio in a Python process managed by uv |
| Reply | Qwen3 0.6B, 1.7B, 4B, and 8B, 4-bit | Native EMLXAxon Qwen3 generation |
| Speech | Kokoro 82M, four voices | Transmuter on the EMLX GPU backend |

The largest combination loads about 8.2 GB of weights. The defaults are Whisper
small, Qwen3 1.7B, and the `af_heart` voice. Set `CHAT_STT`, `CHAT_LLM`, or
`CHAT_VOICE` to change the startup selection.

## Latency

Measured on an Apple M5 with 24 GB of memory, after the first turn:

| Models | First text | First audio |
| --- | ---: | ---: |
| Whisper small, Qwen3 1.7B | 0.9 s | 1.5 s |
| Qwen3-ASR 0.6B, Qwen3 0.6B | 0.3 s | 0.8 s |

The first turn after a model switch compiles the new model. It took up to 6 s
to the first audio.

## Audio

The browser records mono audio and converts it to 16 kHz s16le PCM. It sends
new audio every 0.5 seconds, and the current model transcribes the recording so
far. When you stop recording, the complete audio is one session turn. A
recording stops after 30 seconds.

A new recording, a typed message, or the Stop button cancels the current reply
and stops playback. Microphone access requires `localhost` or HTTPS.
