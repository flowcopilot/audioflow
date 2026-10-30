---
title: Pipecat comparison
description: AudioFlow and Pipecat orchestration over the same model services.
sidebar:
  order: 3
---

`scripts/compare_pipecat.py` measures AudioFlow and Pipecat over the same
shared Nx model services. One Elixir process loads Silero, Whisper tiny,
Qwen3-0.6B, and Kokoro. Pipecat calls these services through private local
pipes; AudioFlow calls them in the same process.

:::caution
This compares orchestration over one inference engine. Pipe transfer, JSON,
Base64, and Python scheduling costs are part of the Pipecat result. It does not
compare Nx with PyTorch, ONNX Runtime, or hosted services.
:::

## Result

Two recordings, 128 measured turns, 64 warmup turns, and 32 serial interruption
checks. All measured turns completed without errors. Detected input and output
PCM hashes agreed, and transcripts and replies matched.

Time to first output, in seconds:

| Simultaneous turns | AudioFlow p50 | AudioFlow p95 | Pipecat p50 | Pipecat p95 |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1.50 | 2.62 | 1.70 | 2.93 |
| 2 | 1.35 | 3.44 | 1.78 | 4.56 |
| 4 | 2.63 | 6.71 | 2.59 | 6.69 |
| 8 | 5.34 | 13.79 | 5.19 | 13.36 |

Both frameworks passed the 10-second p95 rule at four simultaneous turns and
exceeded it at eight. These results apply to the listed models, CPU, software
sinks, and closed workload. They do not establish production capacity.

See the [data](https://github.com/flowcopilot/audioflow/blob/main/validation/comparison.json) and the
[report](https://github.com/flowcopilot/audioflow/blob/main/validation/comparison.html).

## Run

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 mix deps.get
uv run scripts/compare_pipecat.py FIRST.s16le SECOND.s16le \
  --output benchmarks/comparison.json --concurrency 1 2 4 8 \
  --warmup 8 --runs 16 --interrupt-runs 4
python3 scripts/comparison_report.py \
  benchmarks/comparison.json benchmarks/comparison.html
```

Each input must be mono 16 kHz s16le PCM with one detected utterance. See
[`scripts/COMPARISON.md`](https://github.com/flowcopilot/audioflow/blob/main/scripts/COMPARISON.md) for the full method.
