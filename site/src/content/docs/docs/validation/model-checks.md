---
title: Model checks
description: How AudioFlow compares its model output with independent references.
sidebar:
  order: 1
---

The regular tests need no model downloads. With the model flags, tests also
check shared EXLA calls, PCM conversion, and Membrane interruption:

```sh
mix test
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 mix test
```

Model tests are opt-in. They download pinned models unless the files are
already cached:

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 AUDIOFLOW_MODEL_TESTS=1 mix test
```

| Model | Reference | Generator |
| --- | --- | --- |
| Silero VAD | ONNX Runtime probabilities, two concurrent streams | `scripts/silero_reference.py` |
| Kokoro | ONNX Runtime waveform lengths, two voices and speeds | `scripts/kokoro_reference.py` |
| VITS | PyTorch duration from the Transmuter speech guide | None |
| BERT, CLIP | PyTorch vectors | `scripts/multimodal_reference.py` |
| BLIP | Complete reference caption | `scripts/multimodal_reference.py` |
| Qwen3 prompt | Original pinned Jinja template | `scripts/qwen3_prompt_reference.py` |

These checks verify the inference path. They do not measure speech quality.

## Full native pipeline

The full media test uses a public LibriSpeech sample with real Silero, Whisper,
Qwen3, and Kokoro models and a Membrane test sink. It checks transcript content,
reply text, non-silent PCM, and complete delivery. It needs FFmpeg and espeak-ng.

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 AUDIOFLOW_PIPELINE_TESTS=1 \
  mix test test/native_pipeline_test.exs
```

## Conversation checks

The saved [speech conversation checks](https://github.com/flowcopilot/audioflow/blob/main/validation/conversation-smoke.json)
use two utterances with eSpeak NG and Kokoro input voices. With Kokoro inputs,
Whisper transcribed both utterances correctly, and the second spoken reply
recalled the codeword from the first turn. Whisper tiny misread the eSpeak
inputs. Both results are kept with model revisions and PCM hashes.

## HTTP inference check

```sh
AUDIOFLOW_HTTP_MODEL_TESTS=1 \
  AUDIOFLOW_CHAT_ENDPOINT=http://127.0.0.1:18082/v1/chat/completions \
  AUDIOFLOW_LLM=audioflow-qwen mix test test/chat_http_model_test.exs
```

This compares streamed session output with an independent request to the same
deterministic llama.cpp server.
