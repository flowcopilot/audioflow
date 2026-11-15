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

Silero probabilities are compared with independent ONNX Runtime values in
`test/fixtures/silero_reference.json`, for two concurrent streams. Set
`AUDIOFLOW_SILERO_MODEL` to use a local Silero file. The VITS test also checks PCM
size and non-silent output. The Kokoro checks also cover finite samples, PCM
output, and use through a session; they require espeak-ng.

The multimodal checks compare BERT and projected CLIP vectors against independent
PyTorch outputs. The text model has two concurrent callers on one shared serving.
The pinned cat image comes from the Transmuter test fixtures. FFmpeg RGB output
must have the same SHA-256 as the reference image bytes. CLIP comparison allows
small differences between image resize implementations; BLIP checks the complete
reference text. These checks need FFmpeg, but no microphone or sound device.

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MODEL_TESTS=1 mix test test/multimodal_model_test.exs
```

The image session check uses real BLIP with controlled LLM and TTS adapters. It
checks delivery through the session, rather than spoken audio quality.

These checks verify the inference path. They do not measure speech quality.

## Full native pipeline

The full media test uses the public LibriSpeech sample in the pinned Transmuter
repository, with real Silero, Whisper, Qwen3, and Kokoro models and a Membrane test
sink. It checks transcript content, reply text, non-silent PCM, and complete
delivery through the output pipeline. It needs FFmpeg and espeak-ng. It does not
open a sound device.

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 AUDIOFLOW_PIPELINE_TESTS=1 \
  mix test test/native_pipeline_test.exs
```

Set `AUDIOFLOW_PIPELINE_ARTIFACT_DIR` to retain the transcript, reply, PCM, and
timings in a selected directory. Model loading and compilation can take time.

## Conversation checks

The saved [speech conversation checks](https://github.com/flowcopilot/audioflow/blob/main/validation/conversation-smoke.json)
use two utterances with eSpeak NG and Kokoro input voices. With Kokoro inputs,
Whisper transcribed both utterances correctly, and the second spoken reply
recalled the codeword `banana`. Whisper tiny misread the eSpeak inputs. Both
results are retained with model revisions and PCM hashes. These are small checks
of transcription and context use; model quality needs a broader workload. The
native conversation model check uses one Qwen3 serving for two turns and checks
recall of a codeword from the first turn. Its STT and TTS adapters are controlled
test adapters. Qwen3 message prompts are also compared with the original pinned
Jinja template.

## HTTP inference check

```sh
AUDIOFLOW_HTTP_MODEL_TESTS=1 \
  AUDIOFLOW_CHAT_ENDPOINT=http://127.0.0.1:18082/v1/chat/completions \
  AUDIOFLOW_LLM=audioflow-qwen mix test test/req_llm_model_test.exs
```

This compares streamed session output with an independent request to the same
deterministic llama.cpp server. This check uses controlled STT and TTS adapters.
It validates transport output. Model answer accuracy requires a separate
evaluation. The checked local server was llama.cpp 0.8.0, build 11960
(`8642541b2`), with zero GPU layers. It used `Qwen/Qwen3-0.6B-GGUF`, revision
`23749fefcc72300e3a2ad315e1317431b06b590a`, file `Qwen3-0.6B-Q8_0.gguf`. The file
SHA-256 was
`9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031`. The server
used four threads, two slots, a 4,096-token context, and reasoning disabled.
Hybrid voice inference also passed with real Whisper and Kokoro. No hosted cloud
account was used for these checks.

## References

- [Silero frame and context protocol](https://github.com/snakers4/silero-vad/blob/master/src/silero_vad/utils_vad.py)
