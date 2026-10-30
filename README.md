# AudioFlow

AudioFlow is an Elixir voice agent runtime. Each conversation uses an OTP
session. Sessions share model services through an engine-independent adapter.

This is the first implementation of [Brief.md](Brief.md). The core runs without
model downloads. The demo produces fixed text and silent PCM. It does not do
speech recognition or speech synthesis.

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
a reply, call `cancel/1`, flush audio in the playback device, then submit the new
utterance. Cancellation kills the turn task. A shared hardware batch can still
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

`AudioFlow.PCMSink` accepts mono `:s16le` raw audio. Put a resampler and an
utterance framer before the sink. Each buffer must contain a complete utterance.
The sink notifies its parent with `{:audio_flow_input, result}`. The parent must
handle busy input. Raw microphone frames cannot be used as complete utterances.
The application owner must route output PCM to its playback transport.

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

The local example requires a TTS config path and a raw PCM input path. See that
file for the environment variables. Repeat with concurrency 1, 2, 4, and higher.
Record hardware, model revisions, precision, batch settings, and warmup count.
Keep cold runs separate. Use the same recordings, endpoint rules, and models for
a Pipecat comparison. Report p50/p95 latency and error rate. Set the latency and
error limits before selecting a maximum session count. No Pipecat result or
real-time performance claim is included here.

## Work still required

- Implement and validate Silero VAD with resampling and utterance framing.
- Implement Kokoro or VITS preprocessing, voice selection, and PCM output.
  Transmuter alone does not supply these model-specific steps.
- Add playback transport and measure interruption through the playback device.
- Measure the full Membrane → Whisper → LLM → TTS → Membrane path on hardware.
- Compare that path against Pipecat with the same workload.
- Add model routing, embeddings, vision, and distributed worker selection.

## API references

- [Bumblebee audio](https://bumblebee.hexdocs.pm/Bumblebee.Audio.html)
- [Bumblebee text generation](https://bumblebee.hexdocs.pm/Bumblebee.Text.html)
- [Nx.Serving](https://nx.hexdocs.pm/Nx.Serving.html)
- [Membrane sinks](https://membrane-core.hexdocs.pm/Membrane.Sink.html)
- [Transmuter package](https://hex.pm/packages/transmuter)
