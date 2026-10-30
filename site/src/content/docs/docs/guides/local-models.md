---
title: Local models
description: Whisper, Qwen3, Kokoro, and VITS as shared Nx services.
sidebar:
  order: 3
---

Enable the model code for all model commands:

```sh
AUDIOFLOW_ML=1 mix deps.get
AUDIOFLOW_ML=1 mix compile --warnings-as-errors
AUDIOFLOW_ML=1 mix run path/to/your_session.exs
```

## Build a serving once

Build each serving once. Start it under a supervisor with
`AudioFlow.Models.child_spec/3`. Use a distinct atom as each serving name. All
sessions then share the model weights. The default batch size is 1 and the
batch timeout is 5 ms. Tune these values with real workload measurements. See
[`examples/local.exs`](https://github.com/flowcopilot/audioflow/blob/main/examples/local.exs).

`AudioFlow.NxAdapter` calls `Nx.Serving.batched_run/2`. Input and output
functions translate model-specific values. It consumes streaming results in the
calling process. `AudioFlow.Adapters.Function` can call a remote API or another
local engine.

## Speech recognition and text

`AudioFlow.Models.whisper/2` builds a Whisper serving with Bumblebee and EXLA.
`AudioFlow.Models.language_model/2` builds a streaming text serving. The
repository must have a model architecture and tokenizer that Bumblebee supports.

Both builders accept `:load_options` for repository revisions and caches, and
`:model_options` for parameter type and backend. The language builder also
accepts `:generation_options` for token limits and decoding strategy.

The Qwen3 example uses `AudioFlow.Prompt.qwen3/2`, with thinking disabled and a
short spoken-reply instruction. Its format is checked against the pinned
model's original Jinja template. Other language models need their own prompt
format.

Whisper input requires 16 kHz PCM. Resample before submission. Whisper output
is read after utterance transcription. Language model output is streamed and
grouped into sentences before synthesis.

## Kokoro

`AudioFlow.Kokoro.serving/1` builds a shared Kokoro service. It loads the
pinned model, vocabulary, and selected voice style files once. The service
accepts English text with espeak-ng, or direct Kokoro phonemes. Its output is
24 kHz PCM through `AudioFlow.Kokoro.audio/1`.

```sh
AUDIOFLOW_ML=1 mix run examples/kokoro.exs "Hello from AudioFlow." output.wav
```

Voice and speed controls use a request map:

```elixir
serving = AudioFlow.Kokoro.serving(voices: ["af_heart", "am_adam"])
# Start serving once with AudioFlow.Models.child_spec/3, under AudioFlow.TTS.
stream = Nx.Serving.batched_run(AudioFlow.TTS,
  %{text: "Hello.", voice: "am_adam", speed: 1.2})
pcm_chunks = AudioFlow.Kokoro.audio(stream) |> Enum.to_list()
```

Speed must be between 0.5 and 2.0. Only loaded voices are accepted. Inputs
longer than 510 phoneme symbols are split at spaces. Each section emits PCM
after it is generated; Kokoro is not a continuous streaming vocoder.
`:cache_size` bounds the compiled shapes that Transmuter keeps (default 64).

:::note
Install espeak-ng for text input: `brew install espeak-ng` on macOS, or the
`espeak-ng` package on Linux. The tested version is 1.52.0. It only converts
text to phonemes; Kokoro inference runs through Nx, Transmuter, and EXLA.
:::

The default phonemizer supports `en-us` and `en-gb`. It does not provide
Misaki's dictionary and text normalization, so numbers, abbreviations, and
names can sound different. Supply a custom phonemizer tuple or
`%{phonemes: phonemes}` for another front end.

## VITS and SpeechT5

`AudioFlow.Models.text_to_speech/2` builds a VITS or SpeechT5 serving through
Transmuter. `AudioFlow.NxAdapter.speech_audio/1` converts the float waveform to
mono s16le PCM in 20 ms chunks. Set `AUDIOFLOW_TTS=vits` in
`examples/local.exs` for the pinned `Xenova/mms-tts-eng` model.
