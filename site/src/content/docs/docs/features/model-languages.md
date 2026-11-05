---
title: Speech languages
description: Language choices for native Whisper and MMS VITS nodes.
---

Whisper graph nodes accept `"language"`: `"auto"` (the existing automatic
detection default), `"en"`, `"es"`, `"fr"`, `"de"`, `"it"`, `"pt"`, `"ro"`,
`"ja"`, `"zh"`, or `"hi"`. These are a curated subset of Whisper languages.
Bumblebee expects ISO alpha-2 codes and transcribes in the input language by
default; selecting a language does not request translation. `.en` models only
accept `auto` or `en`; conflicting selections raise before model loading.
Each model/language combination gets a separate shared serving cache entry.

```json
{"id":"stt","type":"whisper.stt","options":{"model":"openai/whisper-tiny","language":"es"}}
```

MMS VITS graph nodes now select among real, pinned ONNX repositories:

| Model | Language | Voice |
| --- | --- | --- |
| `Xenova/mms-tts-eng` | English (unchanged default) | Model's single speaker |
| `Xenova/mms-tts-spa` | Spanish | Model's single speaker |
| `Xenova/mms-tts-fra` | French | Model's single speaker |
| `Xenova/mms-tts-deu` | German | Model's single speaker |

```json
{"id":"tts","type":"vits.tts","options":{"model":"Xenova/mms-tts-spa"}}
```

The language comes from the selected model, not a voice label or runtime
translation. These models run through the existing Transmuter VITS serving and
PCM adapter. Kokoro retains its existing English voices and phonemizers;
selecting an English Kokoro voice does not enable multilingual synthesis.
`AudioFlow.ModelLanguages.vits_models/0` exposes language/revision metadata.
Models require the ML profile (`AUDIOFLOW_ML=1`), model downloads, and EXLA.
MMS model cards specify CC-BY-NC-4.0; review their terms for your use case.

Upstream references checked 2026-11-03:

- [Bumblebee Whisper options](https://bumblebee.hexdocs.pm/Bumblebee.Audio.html#speech_to_text_whisper/5)
- ONNX model cards: [Spanish](https://huggingface.co/Xenova/mms-tts-spa), [French](https://huggingface.co/Xenova/mms-tts-fra), [German](https://huggingface.co/Xenova/mms-tts-deu)
- [Pinned Transmuter TTS implementation](https://github.com/georgeguimaraes/transmuter/blob/231028d9ff6f53bd58fa15d9f24d632258369805/lib/transmuter/audio/text_to_speech.ex)

Configuration tests do not prove intelligibility or acoustic quality. Run the
opt-in synthesis smoke test with
`AUDIOFLOW_ML=1 AUDIOFLOW_MODEL_TESTS=1 mix test test/model_language_graph_test.exs`.

For `.en` Whisper repositories the graph omits the language token and passes
`task: nil`: Bumblebee 0.8's monolingual generation config has no language/task
token mappings. This lets both `auto` and `en` use English transcription without
trying to force multilingual tokens.

Validation on 2026-11-03: the opt-in test passed for all three added models,
loading their pinned weights and emitting valid, non-silent 16 kHz s16le PCM
through `Graph.ModelAdapter`. This is an inference/transport smoke test; no
listening panel or intelligibility/quality evaluation was performed.
