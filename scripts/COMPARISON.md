# AudioFlow and Pipecat comparison

`compare_pipecat.py` measures two frameworks over the same shared Nx model
services. One Elixir process loads Silero, Whisper tiny, Qwen3-0.6B, and Kokoro.
The model revisions, decoding options, serving limits, and runtime versions are
saved with the result. The private bridge uses stdin and stdout. It opens no
network listener. No microphone or sound device is opened.

This design compares orchestration with a common inference engine. Pipecat uses
a custom processor for each model stage. It calls the Elixir process through
local pipes. AudioFlow calls the services within that process. Pipe transfer,
JSON, Base64, and Python scheduling costs are included in the Pipecat result.
This is not a comparison against Pipecat's standard provider integrations or
Python model engines. Do not use it to claim that Nx is faster than PyTorch,
ONNX Runtime, or a hosted service.

## Run

Install the project dependencies with both feature flags. The run also needs
espeak-ng. `uv` installs the pinned Pipecat version in an isolated environment.

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 mix deps.get
ffmpeg -v error -i deps/transmuter/test/fixtures/librispeech_0.flac \
  -ac 1 -ar 16000 -f s16le /tmp/speech.s16le
uv run scripts/compare_pipecat.py /tmp/speech.s16le OTHER_INPUT.s16le \
  --output benchmarks/comparison.json --concurrency 1 2 4 \
  --warmup 4 --runs 8 --interrupt-runs 2
```

Each input must be mono signed 16-bit little-endian PCM at 16 kHz. Each file
must have one detected utterance and be at most 30 seconds long. Use at least
two different recordings. The script records file and detected-utterance hashes.
Equal file hashes alone do not establish equal model inputs. Check the
utterance hashes and byte counts in both result sets.

Model downloads and compilation can take time. To use a local Silero file,
set `AUDIOFLOW_SILERO_MODEL`. The bridge pins the local Qwen3 and Kokoro models
and disables conversation history. It does not read API keys or use cloud
inference. Public model downloads can use the normal Hugging Face credentials.

The output file is updated after each attempt. A `.log` file contains model
and bridge output. Failed attempts remain in the results. An attempt has a
200-second limit. Each concurrency level uses fixed groups of simultaneous
turns. This is a closed workload: the next group starts after the preceding
group ends. Warmup and measured turns use the same grouping. Use a warmup count
at least as large as both the input count and the selected concurrency.

## Measurement boundaries

Both paths use a demand-driven Membrane PCM file source, FFmpeg resampling,
Silero, and the same endpoint rules. Input is read as fast as downstream demand
permits. There is no real-time microphone pacing. Each utterance passes through
Whisper, Qwen3, and Kokoro. Text is grouped into sentences with the same Elixir
helper. Both paths produce 20 ms mono PCM chunks at 24 kHz.

AudioFlow sends output through its bounded `Playback` transport and a manual
Membrane sink. Pipecat sends output frames to a software sink. Each Pipecat
processor acknowledges its data frame before the preceding processor can send
another. This keeps the benchmark's data queues bounded. Both output sinks
consume as fast as demand permits. They do not simulate speaker playback time.

Normal timings start before file ingress. AudioFlow starts after its session
and playback controller start. Pipecat starts after pipeline setup reaches
the sink. Model and conversation setup are excluded from turn timings.
All timing fields use microseconds:

- `first_transcript_us`: first transcript received from Whisper.
- `first_text_us`: first sentence-sized LLM chunk.
- `first_audio_us`: first generated PCM chunk received by the framework.
- `first_output_us`: first PCM chunk received by the output sink.
- `duration_us`: complete output delivery for a normal turn.

For interruption, each sink holds after its first PCM chunk. AudioFlow calls
`cancel/1` and waits for output flush. Pipecat sends `InterruptionFrame` and
waits until the output processor has handled it. This is `interrupt_us`.
Both paths check that no further output arrives for 100 ms after the
acknowledgement. Their interruption `duration_us` includes this check. Control
time is separate from native kernel completion. A shared inference call can
continue after its consumer stops. These measurements do not establish an
acoustic stop time.

## Capacity rule

Choose the rule before the measured run. Report p50 and p95 with the sample
count and error rate. The default report rule is zero measured errors and a
p95 `first_output_us` at most 10 seconds. This is a test threshold, not a claim
of conversational quality. Check all lower tested concurrency levels before
accepting a higher one. Label the result "highest passing tested concurrency".
If the highest tested level passes, capacity is not yet bounded. Do not call it
the maximum supported session count.

For production capacity, use longer sustained loads, more speakers, noise,
real-time input pacing, and actual device buffers. For a model-engine
comparison, add independent Pipecat provider adapters with equivalent model
revisions, precision, generation rules, and hardware. Keep those results
separate from this common-engine comparison.
