---
title: Quickstart
description: Run the tests, the demo session, and the benchmark.
---

## Requirements

Use the tool versions in the repository `mise.toml`, or Elixir 1.18 or later
with a compatible OTP version.

```sh
git clone https://github.com/flowcopilot/audioflow.git
cd audioflow
mise install
mix deps.get
```

## Run the core

The core runs without model downloads. The demo adapters produce fixed text and
silent PCM.

```sh
mix test
mix run examples/demo.exs
mix audio_flow.bench --runs 20 --concurrency 4
```

## Start a session

```elixir
{:ok, session} = AudioFlow.start_session(AudioFlow.Adapters.Demo.options())
audio = %AudioFlow.Audio{data: <<0, 0>>, sample_rate: 16_000}
{:ok, turn} = AudioFlow.submit(session, audio)

receive do
  {AudioFlow, ^session, ^turn, event} -> IO.inspect(event)
end

AudioFlow.cancel(session)
AudioFlow.stop_session(session)
```

The owner process receives transcript, text, audio, and terminal events for the
turn. See [Sessions](../guides/sessions/) for the rules.

## Send a typed message

```elixir
{:ok, turn} = AudioFlow.submit(session, %AudioFlow.Text{data: "Hello"})
```

Text turns skip speech recognition. The reply uses the same speech synthesis
and history path as a voice turn.

## Use real models

Enable the model code, then run an example with real inference:

```sh
AUDIOFLOW_ML=1 mix deps.get
AUDIOFLOW_ML=1 mix run examples/kokoro.exs "Hello from AudioFlow." output.wav
```

Kokoro needs `espeak-ng` for text input (`brew install espeak-ng` on macOS).
See [Local models](../guides/local-models/).

## Examples

| File | Shows |
| --- | --- |
| `examples/demo.exs` | A session with demo adapters |
| `examples/routing.exs` | Model routing without downloads |
| `examples/http.exs` | One HTTP chat request |
| `examples/kokoro.exs` | Kokoro speech to a WAV file |
| `examples/vad.exs` | Silero voice detection on a PCM file |
| `examples/local.exs` | Whisper, Qwen3, and Kokoro for benchmarks |
| `examples/media.exs` | PCM file input to speaker output |
| `examples/conversation.exs` | Sequential turns with history |
| `examples/multimodal.exs` | Embeddings and image captions |
| `examples/video.exs` | Descriptions of sampled video frames |
| `examples/chat` | A LiveView voice and text chat |
