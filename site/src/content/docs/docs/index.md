---
title: Introduction
description: What AudioFlow is, and how its parts fit together.
---

AudioFlow is an Elixir runtime for voice, image, and video agents. Each
conversation runs in its own OTP session process. Sessions share model services
through an adapter interface that does not depend on the inference engine.

A voice turn moves through four stages:

1. **Speech recognition** turns the user's audio into a transcript.
2. **The language model** streams a reply as text.
3. **Speech synthesis** turns each reply sentence into PCM audio.
4. **The output transport** plays the audio, and stops it when the user interrupts.

Each stage is an adapter. An adapter can call a native Nx model, a local HTTP
server, a cloud API, or a worker on another Erlang node. The session does not
know which one it calls.

## What is included

- **Sessions** with one active turn, cancellation, deadlines, and bounded output.
- **Conversation history** with limits on turns and bytes.
- **Native models** through Bumblebee, EXLA, and Transmuter: Silero VAD,
  Whisper, Qwen3 and other text models, Kokoro and VITS speech, BERT and CLIP
  embeddings, and BLIP captions.
- **HTTP language models** through streaming chat completions, for llama.cpp and
  compatible cloud endpoints.
- **Image and video input** as packed RGB frames.
- **Model routing** across local and remote workers, with route changes while
  sessions stay open.
- **Membrane input and output**, with voice detection, resampling, and playback
  that can be flushed.

## Build profiles

The core needs no model downloads. Two environment variables add the optional
parts. Each combination uses its own `_build` directory.

| Variable | Adds | Source directory |
| --- | --- | --- |
| none | Sessions, history, routing, HTTP inference | `lib` |
| `AUDIOFLOW_ML=1` | Bumblebee, EXLA, Transmuter models | `lib_ml` |
| `AUDIOFLOW_MEDIA=1` | Membrane audio and video | `lib_media` |

## Next steps

- [Quickstart](quickstart/): run the demo and your first session.
- [Chat example](chat-example/): a browser voice chat on the Apple GPU.
- [Sessions](guides/sessions/): the event format and the turn rules.
