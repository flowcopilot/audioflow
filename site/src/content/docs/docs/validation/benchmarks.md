---
title: Benchmarks
description: Measure time to first transcript, text, and audio per turn.
sidebar:
  order: 2
---

The benchmark writes one CSV row per attempt. It records time to first
transcript, first text, first audio, and turn completion in microseconds. Times
start when the session accepts the utterance. They include task scheduling,
serving queue time, and inference. They exclude microphone capture, endpoint
detection, and playback device delay.

```sh
mix audio_flow.bench --runs 20 --concurrency 4
```

## Real inference

Supply a script that starts shared models and returns
`{session_options, audio}` or `{session_options, audio, metadata}`:

```sh
AUDIOFLOW_ML=1 mix audio_flow.bench --config examples/local.exs \
  --runs 100 --warmup 4 --concurrency 4 --output benchmarks/native.csv
```

`--warmup` rows use `phase=warmup`; other rows use `phase=measured`. Both phases
run at the selected concurrency. Use measured rows for reported latency, and count
all measured failures in the error rate. `--timeout-ms` sets the attempt deadline.
Its default is the session timeout plus five seconds. Cleanup follows the deadline.
A final worker limit also prevents a stalled runner from waiting without an end.

`--output` writes a CSV and a `.meta.json` file with input hashes, model revisions,
and runtime versions. Model logs remain on the console. The sidecar records
warmup settings, runtime and library versions, and loaded AudioFlow module
fingerprints. `setup_us` covers config evaluation and model setup, separately from
turn timings. Without `--output`, stdout also contains any model logs.

:::note
Errors stay in the CSV, so failed runs cannot improve the latency result. A
completed turn with no audio counts as an error.
:::

Rejected input, session exit, cancellation, and benchmark deadlines also produce
rows. Error rows use elapsed attempt time where available. Unobserved timings
remain blank. Blank fields mean that the event did not occur.

`first_text_us` measures the first sentence-sized text chunk from the language
model adapter.

The local example requires `AUDIOFLOW_PCM` and `AUDIOFLOW_LLM`. It uses local
Kokoro by default. Set `AUDIOFLOW_VOICE` to select its voice, or
`AUDIOFLOW_TTS=vits` to use VITS. Set `AUDIOFLOW_TTS_CONFIG` for another adapter.
The example pins Whisper tiny, Qwen3-0.6B, and the selected TTS model. Set
`AUDIOFLOW_LLM_REVISION` to pin another language model and `AUDIOFLOW_HARDWARE` to
add a hardware label to its metadata. The metadata leaves unpinned revisions
empty. The default example uses greedy decoding with at most 64 new tokens, batch
size 1, and a 5 ms batch timeout. Repeat with concurrency 1, 2, 4, and higher.

## Reporting

Record hardware, model revisions, precision, batch settings, and warmup count.
Keep cold runs separate. Report p50 and p95 latency and the error rate. Set the
latency and error limits before you select a maximum session count. Use the same
recordings, endpoint rules, and models for a Pipecat comparison. The CPU run below
does not include a Pipecat comparison or establish real-time performance.

The saved [CPU run data](https://github.com/flowcopilot/audioflow/blob/main/validation/native-cpu.csv),
[metadata](https://github.com/flowcopilot/audioflow/blob/main/validation/native-cpu.csv.meta.json), and
[chart](https://github.com/flowcopilot/audioflow/blob/main/validation/native-cpu.html) have one warmup turn and
three measured turns. They use one recording and one active session. This small
check confirms that the inference path runs. It does not establish session
capacity. Capture, VAD, transport, and playback device delays are excluded from
these measurements.

## Open measurements

- Add echo cancellation for microphone use.
- Measure interruption through a real playback device with loopback audio.
- Use sustained loads, more speakers, noise, and real-time input pacing.
- Compare independent Pipecat model engines with equivalent precision and decoding.
