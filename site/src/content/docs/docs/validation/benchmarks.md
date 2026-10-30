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

`--warmup` rows use `phase=warmup`; other rows use `phase=measured`.
`--timeout-ms` sets the attempt deadline. `--output` writes a CSV and a
`.meta.json` file with input hashes, model revisions, and runtime versions.

:::note
Errors stay in the CSV, so failed runs cannot improve the latency result. A
completed turn with no audio counts as an error.
:::

## Reporting

Record hardware, model revisions, precision, batch settings, and warmup count.
Keep cold runs separate. Report p50 and p95 latency and the error rate. Set the
latency and error limits before you select a maximum session count.

The saved [CPU run data](https://github.com/flowcopilot/audioflow/blob/main/validation/native-cpu.csv) has one warmup turn and
three measured turns with one session. It confirms that the inference path
runs. It does not establish session capacity.
