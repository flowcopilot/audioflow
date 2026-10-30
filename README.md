# AudioFlow

AudioFlow is an Elixir voice agent runtime. Each conversation uses an OTP
session. Sessions share model services through an engine-independent adapter.

This implements the session runtime, native Silero voice detection, Whisper
and text-generation adapters, Kokoro and VITS speech synthesis, and Membrane input from
[Brief.md](Brief.md). The full model benchmark and acoustic interruption
measurements still need work.
The core runs without model downloads. The demo produces fixed text and silent
PCM. Use the model examples for real inference.

## Run

Use the tool versions in `mise.toml`, or Elixir 1.18 or later with a compatible
OTP version.

```sh
mix test
mix run examples/demo.exs
mix audio_flow.bench --runs 20 --concurrency 4
```

## Sessions

```elixir
{:ok, session} = AudioFlow.start_session(AudioFlow.Adapters.Demo.options())
audio = %AudioFlow.Audio{data: <<0, 0>>, sample_rate: 16_000}
{:ok, turn} = AudioFlow.submit(session, audio)

receive do
  {AudioFlow, ^session, ^turn, event} -> IO.inspect(event)
end

AudioFlow.cancel(session)
AudioFlow.stop_session(session)
```

The owner receives transcript, text, audio, and terminal events. See
`AudioFlow` for the event format. Each turn has a unique reference. A session
accepts one turn at a time. Further input returns `{:error, :busy}`. To interrupt
a reply, call `cancel/1`, then submit the new utterance. With an `:output`
transport, cancellation also flushes queued output. Without a transport, the
caller must flush its playback device. Cancellation kills the turn task. A shared hardware batch can still
run to completion.

Input must be mono signed 16-bit little-endian PCM. Input limits, output event
limits, and timeouts are set per session. Defaults are 960,000 input bytes,
1,024 output events, and 30 seconds. An empty transcript ends the turn without
generation. STT chunks form one prompt. LLM chunks go to TTS in sequence.
Use complete sentences for LLM output when possible.

The session stops when its owner exits. Turn failures do not stop the session.
Sessions are temporary supervisor children: a session crash does not restart a
conversation with lost state. The caller must start a new session after a crash.
There is no conversation history yet. Put history and prompt templates in the
application adapter.

Adapter calls acknowledge each output before they continue. The owner must
consume its mailbox. The event limit bounds output per turn, but does not bound
the owner's mailbox across turns. An adapter must also bound individual output
sizes. Do not pass an untrusted client directly as the owner.

## Shared local models

Enable the model code for all model commands:

```sh
AUDIOFLOW_ML=1 mix deps.get
AUDIOFLOW_ML=1 mix compile --warnings-as-errors
AUDIOFLOW_ML=1 mix run path/to/your_session.exs
```

`AudioFlow.Models.whisper/2` builds a Whisper serving with Bumblebee and EXLA.
`AudioFlow.Models.language_model/2` builds a streaming text serving. The selected
repository must have a model architecture and tokenizer supported by Bumblebee.
There is no automatic claim of support for each model named in the brief.

`AudioFlow.Models.text_to_speech/2` builds a VITS or SpeechT5 serving through
Transmuter. `AudioFlow.NxAdapter.speech_audio/1` converts the float waveform to
mono s16le PCM in 20 ms chunks. Values outside the PCM range are clamped.
The model first generates a full sentence waveform. Splitting it into PCM
chunks does not make model inference incremental.

`AudioFlow.Kokoro.serving/1` builds a shared Kokoro service. It loads the pinned
model, vocabulary, and selected voice style files once. The service accepts
English text with espeak-ng, or direct Kokoro phonemes. Its output is 24 kHz
PCM through `AudioFlow.Kokoro.audio/1`.

Install espeak-ng for text input (`brew install espeak-ng` on macOS, or the
`espeak-ng` package on Linux). The tested version is 1.52.0. The executable only
converts text to phonemes. Kokoro inference runs through Nx, Transmuter, and
EXLA. Direct phoneme input does not need this executable. To write a WAV file:

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
section runs as one batch because its waveform length depends on the text.
It emits PCM after that section is generated. It is not a continuous streaming
vocoder. A section's new token and waveform lengths can cause compilation;
`:cache_size` bounds the compiled shapes retained by Transmuter (default 64).

The default phonemizer supports `en-us` and `en-gb`. It preserves punctuation
and converts the English diphthongs and affricates to Kokoro symbols. It does
not provide Misaki's dictionary and text normalization. Numbers, abbreviations,
and names can therefore sound different. Supply a custom phonemizer tuple or
`%{phonemes: phonemes}` when the application needs another front end.

The pinned ONNX graph has a phase error at DC and Nyquist. The builder applies
the Transmuter phase correction before compilation. Voice style row selection
uses `phoneme_count - 1`, as in the original Kokoro inference code.

Transmuter is pinned to a Git revision in `mix.exs` and `mix.lock`. Its current
source API differs from the older Hex release. `examples/local.exs` uses Kokoro
by default. Set `AUDIOFLOW_TTS=vits` for the pinned `Xenova/mms-tts-eng` model.
A custom TTS config is optional.

Build each serving once. Start it under a supervisor with
`AudioFlow.Models.child_spec/3`. Use a distinct atom as each serving name.
The default batch size is 1 and the batch timeout is 5 ms. Tune these values
with real workload measurements. See [examples/local.exs](examples/local.exs).

`AudioFlow.NxAdapter` calls `Nx.Serving.batched_run/2`. Input and output
functions translate model-specific values. It consumes streaming results in
the calling process. It can call an application-owned ONNX serving in the same
way. `AudioFlow.Adapters.Function` can call a remote API or another local engine.
Remote clients must set their own connection and request timeouts.

Whisper input conversion requires 16 kHz PCM. Resample before submission.
Whisper output is currently read after utterance transcription. LLM output is
streamed and grouped into sentences before synthesis. This is not yet a
continuous streaming speech recognizer.

## Membrane input

```sh
AUDIOFLOW_MEDIA=1 mix deps.get
AUDIOFLOW_MEDIA=1 mix compile --warnings-as-errors
```

`AudioFlow.PCMSink` accepts mono `:s16le` raw audio. With its `vad` option, it
accepts audio chunks and submits utterances after endpoint detection:

```elixir
%AudioFlow.PCMSink{
  session: session,
  vad: {AudioFlow.Silero, serving: AudioFlow.VAD},
  endpoint_options: [min_speech_ms: 96, min_silence_ms: 320]
}
```

Start `AudioFlow.VAD` once with `AudioFlow.Silero.serving/2` and
`AudioFlow.Models.child_spec/3`. The Silero source can be a local ONNX file or
`{:hf, "onnx-community/silero-vad", "onnx/model.onnx"}`. Pin the model with
`load_options: [revision: "e71cae966052b992a7eca6b17738916ce0eca4ec"]`.
Each sink keeps its own recurrent state and audio context. Only the weights are
shared. Input must be 16 kHz. Put a resampler before the sink for other rates.

After speech confirmation, the sink cancels the active reply and sends
`{:audio_flow_speech_started, session}` to its parent. A configured output
transport is flushed by the session. Otherwise, the parent must flush playback.
After endpoint detection, it sends `{:audio_flow_input, result}`.
The parent must handle busy input. At end of stream, the sink flushes the final
utterance. Without `vad`, each input buffer must be one complete utterance.

`AudioFlow.VoiceInput` supplies the same frame processing without Membrane. It
retains pre-roll, confirms speech, uses separate start and stop thresholds, and
limits utterance length. It pads a partial final frame with silence. Endpoint
options are documented in the module. Try it with a mono 16 kHz PCM recording:

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_PCM=recording.s16le mix run examples/vad.exs
```

`AudioFlow.Input.attach/3` adds FFmpeg resampling and the session sink to a
Membrane source chain. It requires a voice detector tuple. It converts supported
mono or stereo input to mono s16le at the selected rate (16 kHz by default).
`AudioFlow.InputPipeline` supplies this chain as a complete pipeline. The source
can be `AudioFlow.PCMFileSource` or `Membrane.PortAudio.Source`. The file source
reads bounded chunks and preserves sample timestamps. It rejects incomplete
PCM frames. Set the source format to match the actual file or device.

Echo cancellation is not included. Speaker audio can therefore trigger the detector.

## Output transport

Attach a playback process to a session:

```elixir
sink = %Membrane.PortAudio.Sink{latency: :low,
  ringbuffer_size: 2048, portaudio_buffer_size: 256}
{:ok, playback} = AudioFlow.Playback.start_link(sink: sink)
{:ok, session} = AudioFlow.start_session(
  Keyword.put(session_options, :output, {AudioFlow.Playback, playback}))
```

The sink is application-selected. A sound device opens only when PCM arrives.
Each turn gets its own output pipeline. The queue is limited by `:max_bytes`
(96,000 by default). One further chunk can wait for capacity. Each chunk must
fit within that limit. A full queue blocks the turn worker, while cancellation
remains available in the session. Membrane input prefetch is limited to one
buffer; the device has its own ring buffer. PCM chunks must keep the same sample
rate throughout a turn.

Normal completion drains queued output. PortAudio output is padded to a whole
device block and has a final ring-buffer drain interval before close. The
playback process sends `:drained` after pipeline cleanup. Inference `:done` can
arrive before playback finishes. Cancellation drops the application queue and
closes the old pipeline before it acknowledges. Old turn references are rejected.
A completed inference turn can still be cancelled while its audio is queued.
Session exit also closes its output pipeline.

The observer receives `{AudioFlow.Playback, pid, turn_key, event}`. Events include
`:drained`, `{:first_buffer, %{elapsed_us: us}}`, `{:flushed, %{control_us: us}}`,
back pressure, and failure. First-buffer time ends at the Membrane source;
flush time ends after pipeline cleanup. Neither is a microphone-to-speaker
measurement. A device close can drain a short native buffer. Acoustic
interruption latency still requires a loopback recording and a common clock.

`AudioFlow.Output` defines the transport interface for other output engines.
`push/3` runs in the turn worker, so it can apply back pressure. `flush/2` must
release blocked producers and stop old output. The playback process belongs to
one conversation; use a separate process for each session.

`examples/models.exs` starts shared models. `examples/local.exs` adds a single
utterance for inference benchmarks. `examples/media.exs` connects a PCM file,
resampling, Silero, the session, and PortAudio output. It plays sound when run:

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 AUDIOFLOW_PCM=recording.s16le \
  AUDIOFLOW_LLM=Qwen/Qwen3-0.6B mix run examples/media.exs
```

Set `AUDIOFLOW_INPUT_RATE` and `AUDIOFLOW_INPUT_CHANNELS` for other input formats.
The file example reads at processing speed. Use one utterance for this check.
A live PortAudio source follows the device clock.
The media tests use a controlled sink. They verify back pressure, drain,
cancellation, pipeline failure, and cleanup without opening a sound device.

## Model validation

The regular tests need no model downloads. With the model flags, tests also
check shared EXLA calls, PCM conversion, and Membrane interruption:

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 mix test
```

Model tests are opt-in. They download pinned Silero, VITS, and Kokoro models, unless the
files are already cached. Set `AUDIOFLOW_SILERO_MODEL` to use a local Silero file.

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 AUDIOFLOW_MODEL_TESTS=1 mix test
```

Silero probabilities are compared with independent ONNX Runtime values in
`test/fixtures/silero_reference.json`, for two concurrent streams. The reference
generator is `scripts/silero_reference.py`. The VITS test uses the independent
PyTorch duration recorded in the pinned Transmuter speech guide. It also checks
PCM size and non-silent output. These tests do not measure speech quality.
Kokoro checks compare waveform lengths against ONNX Runtime for two voices,
two speeds, and text input. The reference generator is
`scripts/kokoro_reference.py`. They also check finite samples, PCM output,
and use through a session. These model tests require espeak-ng.

## Benchmarks

The benchmark writes one CSV row per turn. It records time to first transcript,
first text, first audio, and turn completion in microseconds. These times start
when the session accepts the utterance. They include task scheduling, serving
queue time, and inference. They exclude microphone capture, endpoint detection,
and playback device delay. Blank fields mean that the event did not occur.
Errors remain in the CSV so that failed runs cannot improve the latency result.

For real inference, supply a script that starts shared models and returns
`{session_options, audio}`:

```sh
AUDIOFLOW_ML=1 mix audio_flow.bench --config examples/local.exs --runs 100 --concurrency 4
```

The local example requires `AUDIOFLOW_PCM` and `AUDIOFLOW_LLM`. It uses local
Kokoro by default. Set `AUDIOFLOW_VOICE` to select its voice, or
`AUDIOFLOW_TTS=vits` to use VITS. Set `AUDIOFLOW_TTS_CONFIG` for another adapter.
Repeat with concurrency 1, 2, 4, and higher.
Record hardware, model revisions, precision, batch settings, and warmup count.
Keep cold runs separate. Use the same recordings, endpoint rules, and models for
a Pipecat comparison. Report p50/p95 latency and error rate. Set the latency and
error limits before selecting a maximum session count. No Pipecat result or
real-time performance claim is included here.

## Work still required

- Add echo cancellation for microphone use.
- Measure interruption through a real playback device with loopback audio.
- Measure the full Membrane → Whisper → LLM → TTS → Membrane path on hardware.
- Compare that path against Pipecat with the same workload.
- Add model routing, embeddings, vision, and distributed worker selection.

## API references

- [Bumblebee audio](https://bumblebee.hexdocs.pm/Bumblebee.Audio.html)
- [Bumblebee text generation](https://bumblebee.hexdocs.pm/Bumblebee.Text.html)
- [Nx.Serving](https://nx.hexdocs.pm/Nx.Serving.html)
- [Membrane sinks](https://membrane-core.hexdocs.pm/Membrane.Sink.html)
- [Transmuter package](https://hex.pm/packages/transmuter)
- [Pinned Transmuter speech guide](https://github.com/georgeguimaraes/transmuter/blob/231028d9ff6f53bd58fa15d9f24d632258369805/guides/speech_and_audio.md)
- [Silero frame and context protocol](https://github.com/snakers4/silero-vad/blob/master/src/silero_vad/utils_vad.py)
- [Kokoro voice style selection](https://github.com/hexgrad/kokoro/blob/main/kokoro/pipeline.py)
- [Misaki phoneme mapping](https://github.com/hexgrad/misaki/blob/main/misaki/espeak.py)
- [FFmpeg resampler](https://membrane-ffmpeg-swresample-plugin.hexdocs.pm/Membrane.FFmpeg.SWResample.Converter.html)
- [PortAudio plugin](https://hexdocs.pm/membrane_portaudio_plugin/)
