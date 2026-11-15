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
calling process. It can call an application-owned ONNX serving in the same way.
`AudioFlow.Adapters.Function` can call a remote API or another local engine.
Remote clients must set their own connection and request timeouts.

## Speech recognition and text

`AudioFlow.Models.whisper/2` builds a Whisper serving with Bumblebee and EXLA.
`AudioFlow.Models.language_model/2` builds a streaming text serving. The
repository must have a model architecture and tokenizer that Bumblebee supports.
No support is claimed for every model; check each repository before use.

Both builders accept `:load_options` for repository revisions and caches, and
`:model_options` for parameter type and backend. The language builder also
accepts `:generation_options` for token limits and decoding strategy. Serving
options remain separate. The examples load parameters onto `EXLA.Backend`.

The Qwen3 example uses `AudioFlow.Prompt.qwen3/2`, with thinking disabled and a
short spoken-reply instruction. Its format is checked against the pinned
model's original Jinja template. Other language models need their own prompt
format. Streamed text retains its whitespace. Common English titles and initials
stay with the following word. Empty text chunks do not cause a TTS request.

Use `AudioFlow.STT.Bumblebee` for Whisper. It converts the input to 16 kHz.
Whisper output is read after utterance transcription. Language model output is streamed and
grouped into sentences before synthesis. This is not yet a continuous streaming
speech recognizer.

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

Consume the result stream in the calling process. Set the adapter output mapper
to `&AudioFlow.Kokoro.audio/1`. Speed must be between 0.5 and 2.0. Only loaded
voices are accepted. Inputs longer than 510 phoneme symbols are split at spaces,
or at the limit when no space exists. No symbols are silently removed. Each
section runs as one batch because its waveform length depends on the text. Each
section emits PCM after it is generated; Kokoro is not a continuous streaming
vocoder. A section's new token and waveform lengths can cause compilation.
`:cache_size` bounds the compiled shapes that Transmuter keeps (default 64).

:::note
Install espeak-ng for text input: `brew install espeak-ng` on macOS, or the
`espeak-ng` package on Linux. The tested version is 1.52.0. It only converts
text to phonemes; Kokoro inference runs through Nx, Transmuter, and EXLA. Direct
phoneme input does not need this executable.
:::

The default phonemizer supports `en-us` and `en-gb`. It preserves punctuation
and converts the English diphthongs and affricates to Kokoro symbols. It does not provide
Misaki's dictionary and text normalization, so numbers, abbreviations, and
names can sound different. Supply a custom phonemizer tuple or
`%{phonemes: phonemes}` for another front end.

The pinned ONNX graph has a phase error at DC and Nyquist. The builder applies
the Transmuter phase correction before compilation. Voice style row selection
uses `phoneme_count - 1`, as in the original Kokoro inference code.

## VITS and SpeechT5

`AudioFlow.Models.text_to_speech/2` builds a VITS or SpeechT5 serving through
Transmuter. `AudioFlow.NxAdapter.speech_audio/1` converts the float waveform to
mono s16le PCM in 20 ms chunks. Values outside the PCM range are clamped. Set `AUDIOFLOW_TTS=vits` in
`examples/local.exs` for the pinned `Xenova/mms-tts-eng` model. The model first
generates a full sentence waveform. Splitting it into PCM chunks does not make
model inference incremental.

Transmuter is pinned to a Git revision in `mix.exs` and `mix.lock`. Its current
source API differs from the older Hex release. `examples/local.exs` uses Kokoro
by default. A custom TTS config is optional.

## References

- [Bumblebee audio](https://bumblebee.hexdocs.pm/Bumblebee.Audio.html)
- [Bumblebee text generation](https://bumblebee.hexdocs.pm/Bumblebee.Text.html)
- [Nx.Serving](https://nx.hexdocs.pm/Nx.Serving.html)
- [Transmuter package](https://hex.pm/packages/transmuter)
- [Pinned Transmuter speech guide](https://github.com/georgeguimaraes/transmuter/blob/231028d9ff6f53bd58fa15d9f24d632258369805/guides/speech_and_audio.md)
- [Kokoro voice style selection](https://github.com/hexgrad/kokoro/blob/main/kokoro/pipeline.py)
- [Misaki phoneme mapping](https://github.com/hexgrad/misaki/blob/main/misaki/espeak.py)
