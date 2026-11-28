---
title: Input processing
description: Server-side denoising, echo cancellation, and Smart Turn endpoints.
---

Both features are opt-in. Existing VoiceInput callers keep silence endpoints and
unmodified PCM. The order is resampling → SpeexDSP → VAD → Smart Turn on silence
→ utterance submission. The audio submitted to STT is the processed audio.

## SpeexDSP 1.2.1

This uses the real native SpeexDSP preprocessor and reference AEC, rather than
claiming RNNoise/WebRTC compatibility. Install SpeexDSP development headers, a C
compiler, and pkg-config, then build once for your deployment platform:

```sh
cc -O2 -Wall -Wextra -Werror native/speex_dsp.c \
  $(pkg-config --cflags --libs speexdsp) -o /absolute/path/audioflow-speex-dsp
```

The worker is a standalone process (no NIF). Each input stream needs its own
worker; adaptive filter state must not be shared between microphones. Its fixed
format matches Silero: mono signed 16-bit little-endian PCM, 16 kHz, 512 samples.
It uses a 200 ms echo tail and -20 dB noise suppression. AGC is disabled. Native
state persists across utterances; stop/recreate the worker for a new stream.

```elixir
{:ok, dsp} = AudioFlow.SpeexDSP.start_link(executable: "/absolute/path/audioflow-speex-dsp")
input = AudioFlow.VoiceInput.new({AudioFlow.Silero, serving: silero},
  preprocessor: {AudioFlow.SpeexDSP, worker: dsp})
{events, input} = AudioFlow.VoiceInput.push(input, captured_audio, aligned_speaker_audio)
```

`push/3` requires equally sized capture/reference chunks with the same sample
rate. Splits across detector frames are buffered together. `push/2` supplies zero
reference: noise suppression still runs, but this cannot cancel speaker echo.
A worker failure or 200 ms timeout raises, preventing accidental unfiltered VAD.
The worker process survives it: after a timeout it drops the late reply (or, if
replies keep backing up, restarts the native program), and after a program exit it
starts a new one. A restarted program has fresh adaptive-filter state. The native
executable accepts `aec-only` to disable preprocessing for isolation/diagnostics.

For Membrane, pass the same `:preprocessor` in `:endpoint_options` to
`AudioFlow.Input.attach/3` or `InputPipeline.start_link/1`. The PCMSink runs it
after FFmpeg resampling and before VAD. `InputPipeline.reference(pipeline, audio)`
queues speaker PCM for subsequent capture. Reference must already be resampled to
the capture rate, delivered after stream format negotiation and before the
corresponding capture, and aligned by the caller. The queue is capped at one
second; missing samples are treated as zero. Overruns/invalid format raise.

**Remaining integration for #9:** the existing PortAudio playback path does not
provide a synchronized render-reference tap. Merely queuing TTS generated audio
is insufficient: it must represent audio actually rendered at the device, with
appropriate latency alignment. This PR provides the working canceller and ingress,
but does not wire or validate that device clock/alignment. It does not claim
measured room acoustics, double-talk robustness, nonlinear echo removal, or
background voice removal. See the [official Speex AEC timing requirements](https://www.speex.org/docs/manual/speex-manual/node7.html).

## Smart Turn v3.1 CPU

The model runs in a persistent Python ONNX Runtime process. This avoids pretending
that the existing Transmuter import supports the quantized graph. Python 3.12 and
the pinned dependencies are required; the ordinary Elixir suite needs neither.

```sh
uv venv /tmp/audioflow-turn --python 3.12
uv pip install --python /tmp/audioflow-turn/bin/python \
  -r priv/audio_flow/requirements-smart-turn.txt
curl -L --fail -o /absolute/path/smart-turn-v3.1-cpu.onnx \
  https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/f766f81d3cfdf7737ac64aad813d91bbfd56bf93/smart-turn-v3.1-cpu.onnx
sha256sum /absolute/path/smart-turn-v3.1-cpu.onnx
# fb68d55c2d542ce79e44b12013bfd571e90df8594ab096d757198e851b0c6594
```

The worker verifies this hash on startup and makes no runtime downloads. Model
license: BSD-2-Clause; retain upstream license when redistributing weights.
Preprocessing follows the pinned upstream
[inference](https://github.com/pipecat-ai/smart-turn/blob/4786657e242dfe77dd138699ac564ee074a2a543/inference.py)
and [audio padding](https://github.com/pipecat-ai/smart-turn/blob/4786657e242dfe77dd138699ac564ee074a2a543/audio_utils.py):
last eight seconds of 16 kHz PCM, left zero padding, normalized Whisper features,
`input_features` ONNX input, and sigmoid probability output.

```elixir
{:ok, turn} = AudioFlow.SmartTurn.start_link(
  executable: "/tmp/audioflow-turn/bin/python",
  args: [Path.expand("priv/audio_flow/smart_turn.py"), "/absolute/path/smart-turn-v3.1-cpu.onnx"])
endpoint_options = [
  preprocessor: {AudioFlow.SpeexDSP, worker: dsp},
  turn_detector: {AudioFlow.SmartTurn, worker: turn},
  turn_threshold: 0.5,
  turn_timeout_ms: 600,
  turn_retry_ms: 320,
  max_semantic_silence_ms: 2000
]
input = AudioFlow.VoiceInput.new({AudioFlow.Silero, serving: silero}, endpoint_options)
# Or supply endpoint_options to InputPipeline.start_link/1.
```

After minimum VAD silence, completion emits `:semantic`; incompletion retains the
utterance, allowing resumed speech to join it. Inference retries at most once per
`turn_retry_ms` of audio. Two seconds of continuous silence forces
`:semantic_limit`; the existing maximum utterance and EOS bounds still apply.
Errors, invalid probabilities, and timeouts emit `:semantic_fallback`, using the
already satisfied silence endpoint. A Smart Turn request has a 500 ms deadline
that covers queue time and inference. On timeout the worker keeps running: it
drops the late result, and restarts the Python process only if results keep
backing up, so a slow call does not disable semantic checks for the rest of the
stream. VoiceInput bounds the whole model call (1–5000 ms configurable); workers
have a 30-second startup limit. Callers own worker supervision and shutdown.
The model sees at most the last eight seconds of the utterance.

By default calls are synchronous: each silence decision may pause the calling
process (a connection, session, or Membrane sink) for up to the configured
timeout. Set `async_turn: true` to avoid this. `push/2,3` then only starts the
check and returns; capture keeps being buffered, and the owner passes the check's
messages to `VoiceInput.handle_info/2`, which returns `{:ok, events, input}` or
`:unknown`. The resulting utterance holds every frame consumed up to that call.
Speech that resumes while a check is pending, a hard limit, or `flush/1` drops the
check. `AudioFlow.PCMSink` routes these messages itself. See the
`AudioFlow.VoiceInput` module documentation for the exact event order.

Several streams can share one Smart Turn worker: it keeps no per-stream state.
Requests are served in order, a request whose deadline passed or whose caller
exited is skipped without reaching Python, and a failed check only costs that
stream a `:semantic_fallback`. The trade-off is that one Python process runs one
inference at a time. When many streams reach a silence decision together, later
ones wait in line and may exceed the 500 ms deadline, so they fall back to the
silence endpoint. Use a worker per stream (or per few streams) when you need
predictable latency under load, and a shared worker when memory matters more.
Do not share SpeexDSP workers: their adaptive filter state belongs to one
microphone. These tests establish execution and endpoint behavior, not speech
accuracy or latency targets.

## Verification

```sh
mix test
AUDIOFLOW_SPEEX_EXECUTABLE=/absolute/path/audioflow-speex-dsp \
  mix test test/native_input_processing_test.exs
AUDIOFLOW_MODEL_TESTS=1 \
AUDIOFLOW_SMART_TURN_PYTHON=/tmp/audioflow-turn/bin/python \
AUDIOFLOW_SMART_TURN_MODEL=/absolute/path/smart-turn-v3.1-cpu.onnx \
  mix test test/native_input_processing_test.exs
AUDIOFLOW_MEDIA=1 mix test test/input_test.exs
```

Core tests use deterministic detector/model fixtures to check joining,
completion, limits, failures, timeout, preprocessing order, and reference splits.
Optional native tests check stationary-noise attenuation, delayed scaled echo
convergence, and near-end signal retention. Optional model tests verify the exact
model hash, deterministic real inference and a reference probability, and the
last-eight-second cropping contract. No regular test downloads model weights.
