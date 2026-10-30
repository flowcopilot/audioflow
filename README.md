# AudioFlow

AudioFlow is an Elixir voice, image, and video agent runtime. Each conversation uses an OTP
session. Sessions share model services through an engine-independent adapter.
Optional bounded history keeps successful conversation turns in each session.

This implements the session runtime, model routing, distributed inference workers,
native Silero voice detection, Whisper and text-generation adapters, Kokoro and
VITS speech synthesis, and Membrane audio and video input from
[Brief.md](Brief.md). The native media path has a recorded-speech integration
check and a controlled Pipecat comparison. Output interruption is measured at
the software transport. Acoustic interruption needs a device loopback check.
HTTP language inference can use a compatible local server or cloud endpoint.
Text embeddings, CLIP image embeddings, and BLIP image captions use shared
native model services. Their model checks use independent PyTorch references.
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

Core, ML, media, and combined ML/media builds use separate `_build` directories.
Changing a feature flag does not remove modules used by another build profile.

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

Adapter calls acknowledge each output before they continue. The owner must
consume its mailbox. The event limit bounds output per turn, but does not bound
the owner's mailbox across turns. An adapter must also bound individual output
sizes. Do not pass an untrusted client directly as the owner.

## Conversation history

Enable history when the LLM adapter accepts chat messages:

```elixir
{:ok, session} = AudioFlow.start_session(
  Keyword.put(session_options, :history, [max_turns: 8, max_bytes: 16_384]))
```

`history: true` uses these defaults. History is disabled by default, so existing
adapters continue to receive one transcript string. With history enabled, the
LLM receives a list of `%{role: :user | :assistant, content: text}` maps. Saved
user/assistant pairs precede the current user message. `Prompt.qwen3/2` and
`Adapters.ChatHTTP` accept this format. Custom adapters and routing functions
must accept the message list when history is enabled. System instructions stay
in the model adapter or prompt formatter.

`max_turns` counts complete saved pairs. `max_bytes` counts UTF-8 text content.
The runtime removes the oldest complete pairs to fit the new prompt. It also
removes old pairs when a successful reply makes saved history exceed a limit.
Current input and reply text must fit as one pair; excess text ends the turn
with `{:error, :context_limit, metrics}`. The input limit also applies while
transcript or description chunks arrive. The budget excludes role fields,
prompt delimiters, and system instructions. It is a byte limit, not a model
token limit. Set model sequence limits for the chosen workload.

Only nonempty user and assistant text becomes a saved pair. The session saves
it after successful inference and acknowledgement from `Output.finish/2`.
Failed or cancelled active turns leave the previous saved pairs intact.
Transport completion can precede physical playback. A cancellation after
`:done` flushes output and keeps that completed pair. Each session owns its
history, including when sessions share the same inference worker.

Image descriptions use the user role, so later voice turns can refer to the
described image. History stores text, rather than raw image or audio data.
Clear the saved text while the session is idle:

```elixir
:ok = AudioFlow.clear_history(session)
```

An active turn returns `{:error, :busy}`. Clearing a session with history
disabled is an idempotent operation. History lasts for the session process;
owner exit or a session crash ends it.

Set `AUDIOFLOW_HISTORY=1` for `examples/models.exs`, `examples/media.exs`, and
`examples/local.exs`. The supplied history prompt supports native Qwen3 or an
HTTP chat engine. Other native models need their own message formatter.
Benchmark attempts use new sessions, so their history starts empty.

For sequential recorded turns on one session:

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_HISTORY=1 AUDIOFLOW_LLM=Qwen/Qwen3-0.6B \
  mix run examples/conversation.exs output first.s16le second.s16le
```

Inputs are mono 16 kHz s16le PCM. The example loads shared models once and
writes one PCM file plus JSON metadata per turn. It does not open a sound device.
The native conversation model check uses one Qwen3 serving for two turns and
checks recall of a codeword from the first turn. Its STT and TTS adapters are
controlled test adapters. Qwen3 message prompts are also compared with the
original pinned Jinja template.

The saved [speech conversation checks](validation/conversation-smoke.json)
use the same two utterances with eSpeak NG and Kokoro input voices. With Kokoro
inputs, Whisper transcribed both utterances correctly and the second spoken
reply recalled the codeword `banana`. Whisper tiny misread the eSpeak inputs.
Both results are retained with model revisions and PCM hashes. These are small
checks of transcription and context use; model quality needs a broader workload.

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
Both builders accept `:load_options` for repository revisions and caches, and
`:model_options` for parameter type and backend. The language builder also
accepts `:generation_options` for token limits and decoding strategy. Serving
options remain separate. The examples load parameters onto `EXLA.Backend`.

The Qwen3 example uses `AudioFlow.Prompt.qwen3/2`, with thinking disabled and a
short spoken-reply instruction. Its format is checked against the pinned model's
original Jinja template. Other language models need their own prompt format.
Streamed text retains its whitespace. Common English titles and initials stay
with the following word. Empty text chunks do not cause a TTS request.

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

## HTTP language inference

`AudioFlow.Adapters.ChatHTTP` implements streaming chat completions for
compatible local servers and cloud endpoints. It uses the same adapter
interface as the native models. No native model dependencies are required:

```elixir
llm = {AudioFlow.Adapters.ChatHTTP,
  endpoint: "http://127.0.0.1:18082/v1/chat/completions",
  model: "audioflow-qwen",
  parameters: %{temperature: 0, max_tokens: 64}}
{:ok, session} = AudioFlow.start_session(
  Keyword.put(session_options, :llm, llm))
```

Supply the complete endpoint URL and the model ID expected by the server.
Use HTTPS for cloud endpoints. Set `:api_key` to a string or a zero-argument
function. For example, `fn -> System.fetch_env!("AUDIOFLOW_CHAT_API_KEY") end`
reads the key when a request starts. Additional `:headers` can hold provider
options. The adapter does not follow redirects or retry HTTP status errors.
TLS uses the HTTP client's default certificate and hostname verification.

Input can be one string or a list of `%{role: :user | :assistant, content: text}`
messages. `:system` sets the system instruction. Its default requests one short
spoken sentence. The adapter prepends this instruction once. `:parameters`
holds provider-specific JSON fields. The adapter fixes `model`, `messages`,
`stream: true`, and `n: 1`. The default token limit is `max_tokens: 128`.
Supply `max_completion_tokens` instead when the provider requires that field.

SSE decoding accepts split UTF-8, CR/LF line endings, comments, and multiline
data. Output uses sentence chunks with whitespace preserved. A complete stop
event and `[DONE]` are required before the final text fragment is emitted.
Truncation, incomplete streams, tool calls, refusals, invalid events, and empty
replies return errors. Earlier complete sentences can already have reached TTS.
This adapter handles text chat. It does not implement the Responses API or
remote STT, TTS, and tool execution.

The shared Finch pool uses HTTP/1 so the output callback applies back pressure
to socket reads. Cancellation closes the active connection. A failed output
callback also releases the connection. The limits are:

| Option | Default | Bound |
| --- | ---: | --- |
| `max_request_bytes` | 65,536 | Encoded request body |
| `max_response_bytes` | 262,144 | Complete response body |
| `max_event_bytes` | 16,384 | One SSE event |
| `max_text_bytes` | 8,192 | Generated text |
| `timeout_ms` | 30,000 | Budget for response reads |
| `receive_timeout_ms` | 10,000 | Wait for a response chunk |
| `pool_timeout_ms` | 5,000 | Wait for a connection |

Connections have a five-second connection timeout. The response-read budget
excludes pool checkout, connection setup, and time blocked in the output
callback. Use a session or worker deadline to bound the complete operation.

Run a direct text request:

```sh
AUDIOFLOW_CHAT_ENDPOINT=http://127.0.0.1:18082/v1/chat/completions \
  AUDIOFLOW_LLM=audioflow-qwen mix run examples/http.exs "Say hello."
```

Set `AUDIOFLOW_CHAT_API_KEY` locally when authentication is required. To use
HTTP language inference with native Whisper and Kokoro, set
`AUDIOFLOW_LLM_ENGINE=http` and `AUDIOFLOW_CHAT_ENDPOINT` for
`examples/local.exs` or `examples/media.exs`. `AUDIOFLOW_LLM` becomes the server's
model ID. This mode does not load a native language model. The benchmark
metadata uses `mode=hybrid_inference` and records the language engine as HTTP.
Optional `AUDIOFLOW_LLM_SOURCE` and `AUDIOFLOW_LLM_REVISION` identify the deployed
weights. The metadata does not contain the API key or endpoint query string.

The real HTTP check compares streamed output through a session with an
independent nonstreamed request to the same deterministic server:

```sh
AUDIOFLOW_HTTP_MODEL_TESTS=1 \
  AUDIOFLOW_CHAT_ENDPOINT=http://127.0.0.1:18082/v1/chat/completions \
  AUDIOFLOW_LLM=audioflow-qwen mix test test/chat_http_model_test.exs
```

This check uses controlled STT and TTS adapters. It validates transport output.
Model answer accuracy requires a separate evaluation. The checked local server
was llama.cpp 0.8.0, build 11960 (`8642541b2`), with zero GPU layers. It used
`Qwen/Qwen3-0.6B-GGUF`, revision
`23749fefcc72300e3a2ad315e1317431b06b590a`, file `Qwen3-0.6B-Q8_0.gguf`.
The file SHA-256 was
`9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031`.
The server used four threads, two slots, a 4,096-token context, and reasoning
disabled. Hybrid voice inference also passed with real Whisper and Kokoro.
No hosted cloud account was used for these checks.

## Images and embeddings

`AudioFlow.Models.text_embedding/2` builds a shared text embedding serving. Its
defaults use attention-masked mean pooling and L2 normalization. These defaults
match `sentence-transformers/all-MiniLM-L6-v2`, a BERT model with 384 output
values. Other models can need different pooling, output attributes, or input
prefixes. Set these through the serving options and the adapter input mapper.
The library does not infer a retrieval task or add a query prefix.

`AudioFlow.Models.clip_image_embedding/2` loads the CLIP vision model and its
trained projection. It emits normalized vectors in the joint CLIP text-image
space. The tested CLIP model emits 512 values. BERT and CLIP vectors use
different spaces; do not compare them directly.
`AudioFlow.Models.image_captioning/2` builds a caption serving for supported
models such as BLIP. It generates a complete caption before returning it.

All three builders accept `:load_options` for revisions and caches, and
`:model_options` for parameter type and backend. Captioning also accepts
`:generation_options`. Set `:compile` to bound input shapes. Text embedding
sequence lengths can truncate long input; set the length for the chosen model
and workload. Load the models once and use `Models.child_spec/3` to start their
shared servings. The same `NxAdapter`, `Worker`, and `Router` interfaces apply
to these models.

Use `NxAdapter.embedding/1` to emit one portable list of numbers, or supply an
output mapper that retains the tensor. This allows applications to keep vectors
on the device. `NxAdapter.captions/1` emits caption strings. The examples pin
the model revisions and use EXLA parameters:

```sh
AUDIOFLOW_ML=1 mix run examples/multimodal.exs embed "Two cats on a couch."
AUDIOFLOW_ML=1 mix run examples/multimodal.exs image-embedding image.png
AUDIOFLOW_ML=1 mix run examples/multimodal.exs describe image.png
```

Image modes need the FFmpeg and ffprobe CLIs. They decode the first frame to
RGB. The models run through Bumblebee, Nx, and EXLA.

A session with a `:vision` adapter can accept an `AudioFlow.Image`:

```elixir
vision = {AudioFlow.NxAdapter,
  serving: MyApp.CaptionModel,
  input: &AudioFlow.NxAdapter.image_input/1,
  output: &AudioFlow.NxAdapter.captions/1}
{:ok, session} = AudioFlow.start_session(
  Keyword.put(session_options, :vision, vision))
{:ok, turn} = AudioFlow.submit(session,
  %AudioFlow.Image{data: rgb_bytes, width: width, height: height})
```

Image data must use packed RGB, with three unsigned 8-bit channels per pixel
in row order. Its byte count must equal `width * height * 3`. The session rejects
invalid images and images above `:max_image_bytes` (6,291,456 by default). Image
turns emit `{:description, text}` events. All description chunks form one prompt
for the LLM, then the reply follows the normal TTS and playback path. The
terminal metrics include `first_description_us`. Image-only sessions can omit
`:stt`. Submission without the required input adapter returns
`{:error, {:unsupported_input, stage}}`.

Audio and image turns share one active-turn limit. Both support cancellation,
deadlines, and output limits. An image can include an integer `:pts` in
nanoseconds. The session adds this time to the description sent to the LLM and
saved in history. The `:description` event keeps the original model text.

## Video input

With `AUDIOFLOW_MEDIA=1`, `AudioFlow.Video.frames/2` reads H.264 video from a
local MP4 file. It also accepts an application-supplied Membrane raw-video
source, such as a camera source. It converts selected frames to packed RGB:

```elixir
for frame <- AudioFlow.Video.frames("input.mp4",
      interval_ms: 1_000, width: 384, height: 384) do
  {:ok, turn} = AudioFlow.submit(session, frame)
  # Wait for this turn to finish before you read the next frame.
end
```

The interval is the minimum time between selected frames. The reader uses
presentation timestamps, rather than frame counts. By default, time starts at
the first decoded frame. Set `normalize_timestamps?: false` to keep decoder
timestamps, including MP4 composition offsets. These times do not account for
MP4 edit lists or provide audio and video synchronization.

The default track is the H.264 track with the lowest ID. Use `:track_id` to
select another H.264 track. Other tracks, including audio, are discarded. Files
with metadata at either end are supported. Unsupported tracks and decode errors
produce errors; they do not end the calling process when you use the manual API.

The reader allows one pending read and uses small RGB queues. The default frame
limit is 6,291,456 bytes. Set `:max_frame_bytes` to change it. Optional `:width`
and `:height` values must be positive even integers. Scaling keeps the aspect
ratio and adds padding. The frame limit applies after scaling. Decoder working
memory and MP4 indexes are separate from this limit. Decoding follows demand;
the reader does not pace frames against a clock.

`frames/2` closes the reader at EOF, on an early halt, or after a consumer error.
It raises on a read error. Its `:timeout_ms` option sets the limit for each read
(30 seconds by default). For manual control, use
`Video.start_link(location: path)` or `Video.start_link(source: source)`, then
`Video.next_frame(reader, timeout_ms)` and `Video.close(reader)`. A reader also
stops when its owner exits.

The video example uses shared BLIP, Qwen3, and Kokoro services. It waits for one
frame turn before it reads another. History supplies the previous description
for comparison. It saves descriptions, replies, timings, and speech PCM:

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 mix run examples/video.exs input.mp4 output
```

`AUDIOFLOW_VIDEO_INTERVAL_MS` sets the interval (1,000 by default), and
`AUDIOFLOW_VIDEO_FRAMES` sets the frame limit (16 by default). This is sampled
frame analysis. It does not track objects or motion between frames. A two-scene
model check produced correct individual descriptions, but Qwen3-0.6B added an
unsupported action during comparison. Model output needs assessment for the
intended use.

## Model routing and distributed workers

`AudioFlow.Worker` runs an adapter with a fixed limit on active requests. It
rejects requests above that limit. It does not keep a waiting queue. Start
shared model services first, then start their workers under a supervisor:

```elixir
llm_adapter = {AudioFlow.NxAdapter,
  serving: AudioFlow.LLM,
  input: &AudioFlow.Prompt.qwen3/1,
  output: &AudioFlow.NxAdapter.sentences/1}

children = [
  {AudioFlow.Worker,
   name: MyApp.LocalLLM, adapter: llm_adapter,
   max_concurrency: 4, timeout_ms: 120_000},
  {AudioFlow.Router,
   name: MyApp.Routes,
   routes: %{voice: [MyApp.LocalLLM, {MyApp.RemoteLLM, :"ml@worker"}]}}
]
{:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

options = Keyword.put(session_options, :llm,
  {AudioFlow.Router, router: MyApp.Routes, route: :voice, timeout_ms: 120_000})
{:ok, session} = AudioFlow.start_session(options)
```

The remote node must run AudioFlow and a worker named `MyApp.RemoteLLM`. Its
adapter uses model services on that node. Erlang distribution must already
connect the nodes. Use compatible code on trusted nodes. Inputs and outputs
cross the connection. Model weights remain in their shared services.
Only connected remote nodes are eligible. Reconnect a node before routing to
it again. If a node fails while admission is in progress, the request ends with
an error. Its admission status is unknown, so the router does not retry it.
All engines use the same adapter interface. A worker can use `NxAdapter` or an
application adapter for ONNX, llama.cpp, or a cloud API. Cloud clients must set
their own connection and request timeouts.

Routes rotate the starting worker for each request. A busy or unavailable worker
is skipped. An error after admission ends the request. The router does not
repeat partial speech on another worker. If all workers reject the request, the
caller receives `{:error, {:no_worker_available, route, reasons}}`.

Change a route while sessions remain open:

```elixir
AudioFlow.Router.put_route(MyApp.Routes, :voice, [{MyApp.RemoteLLM, :"ml@worker"}])
```

The change applies to subsequent adapter calls. Active requests keep their
worker. An empty worker list disables the route. `:route` can also be a function
that selects a route key from the adapter input. For example, a text-length or
language policy can select a model without changing the session pipeline.

Each output chunk waits for its caller's acknowledgement. Caller exit and
session cancellation stop the worker task, including on a remote node. Worker
exit or node loss ends the active request with an error. Each worker has a
request deadline, and the router has a deadline for the complete call. Cleanup
can take up to one additional second. A hardware batch already submitted to a
shared serving can still run to completion. Set worker limits and deadlines to
match measured model capacity and the session timeout.

Run the local routing example without model downloads:

```sh
mix run examples/routing.exs
```

The distributed checks start a second local Erlang node. They check remote
output, cancellation, and node loss through the worker protocol:

```sh
AUDIOFLOW_DISTRIBUTED_TESTS=1 elixir --sname audioflow_test -S mix test
```

These checks use controlled adapters. They do not measure network latency or
model capacity across machines.

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

The multimodal model checks compare BERT and projected CLIP vectors against
independent PyTorch outputs. They also check a real BLIP caption through an
image session. The text model has two concurrent callers on one shared serving.
The pinned cat image comes from the Transmuter test fixtures. FFmpeg RGB output
must have the same SHA-256 as the reference image bytes. The reference generator
is `scripts/multimodal_reference.py`. CLIP comparison allows small differences
between image resize implementations; BLIP checks the complete reference text.
These checks need FFmpeg, but no microphone or sound device.

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MODEL_TESTS=1 mix test test/multimodal_model_test.exs
```

The image session check uses real BLIP with controlled LLM and TTS adapters.
It checks delivery through the session, rather than spoken audio quality.

The full native media test is a separate opt-in check. It needs the FFmpeg CLI
and espeak-ng. It uses the public LibriSpeech sample in the pinned Transmuter
repository, real Silero, Whisper, Qwen3, and Kokoro models, and a Membrane test
sink. It checks transcript content, reply text, non-silent PCM, and complete
delivery through the output pipeline. It does not open a sound device.

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 AUDIOFLOW_PIPELINE_TESTS=1 \
  mix test test/native_pipeline_test.exs
```

Set `AUDIOFLOW_PIPELINE_ARTIFACT_DIR` to retain the transcript, reply, PCM, and
timings in a selected directory. Model loading and compilation can take time.

## Benchmarks

The benchmark writes one CSV row per attempt. It records time to first transcript,
first text, first audio, and turn completion in microseconds. These times start
when the session accepts the utterance. They include task scheduling, serving
queue time, and inference. They exclude microphone capture, endpoint detection,
and playback device delay. Blank fields mean that the event did not occur.
Errors remain in the CSV so that failed runs cannot improve the latency result.
A completed turn with no audio is an error for this voice benchmark. Rejected
input, session exit, cancellation, and benchmark deadlines also produce rows.
Error rows use elapsed attempt time where available. Unobserved timings remain
blank.

`first_text_us` measures the first sentence-sized text chunk from the language
model adapter.

For real inference, supply a script that starts shared models and returns
`{session_options, audio}` or `{session_options, audio, metadata}`:

```sh
AUDIOFLOW_ML=1 mix audio_flow.bench --config examples/local.exs \
  --runs 100 --warmup 4 --concurrency 4 --output benchmarks/native.csv
```

`--warmup` rows use `phase=warmup`; other rows use `phase=measured`. Both phases
run at the selected concurrency. Use measured rows for reported latency, and
count all measured failures in the error rate. `--timeout-ms` sets the attempt
deadline. Its default is the session timeout plus five seconds. Cleanup follows
the deadline. A final worker limit also prevents a stalled runner from waiting
without an end.

`--output` writes clean CSV and a `.meta.json` sidecar. Model logs remain on the
console. The sidecar records input SHA-256, model revisions from the config,
warmup settings, runtime and library versions, and loaded AudioFlow module
fingerprints. `setup_us` covers config evaluation and model setup, separately
from turn timings. Without `--output`, stdout also contains any model logs.

The local example requires `AUDIOFLOW_PCM` and `AUDIOFLOW_LLM`. It uses local
Kokoro by default. Set `AUDIOFLOW_VOICE` to select its voice, or
`AUDIOFLOW_TTS=vits` to use VITS. Set `AUDIOFLOW_TTS_CONFIG` for another adapter.
Repeat with concurrency 1, 2, 4, and higher.
The example pins Whisper tiny, Qwen3-0.6B, and the selected TTS model. Set
`AUDIOFLOW_LLM_REVISION` to pin another language model and `AUDIOFLOW_HARDWARE`
to add a hardware label to its metadata. The metadata leaves unpinned revisions
empty. The default example uses greedy decoding with at most 64 new tokens,
batch size 1, and a 5 ms batch timeout.
Record hardware, model revisions, precision, batch settings, and warmup count.
Keep cold runs separate. Use the same recordings, endpoint rules, and models for
a Pipecat comparison. Report p50/p95 latency and error rate. Set the latency and
error limits before selecting a maximum session count. The inference-only run
below does not include a Pipecat comparison or establish real-time performance.

The saved [CPU run data](validation/native-cpu.csv),
[metadata](validation/native-cpu.csv.meta.json), and
[chart](validation/native-cpu.html) contain one warmup turn and three measured
turns. They use one recording and one active session. This small check confirms
that the inference path runs. It does not establish session capacity. Capture,
VAD, transport, and playback device delays are excluded from these measurements.

The [common-engine comparison guide](scripts/COMPARISON.md) provides a full media
runner for AudioFlow and Pipecat. Both use the same shared Silero, Whisper,
Qwen3, and Kokoro services. The run includes Membrane file input, resampling,
endpoint detection, model queues, and software output delivery. Pipecat calls
the model stages through private local pipes. Its result includes that transfer
cost. This comparison does not compare Nx against Python inference engines.

```sh
uv run scripts/compare_pipecat.py FIRST.s16le SECOND.s16le \
  --output benchmarks/comparison.json --concurrency 1 2 4 8 \
  --warmup 8 --runs 16 --interrupt-runs 4
python3 scripts/comparison_report.py \
  benchmarks/comparison.json benchmarks/comparison.html
```

The runner retains failed attempts, input hashes, detected-utterance hashes,
output PCM hashes, model revisions, and source fingerprints. It separates warmup,
measured turns, and serial interruption checks. Choose `--max-first-output-ms`
before the run. The default rule allows no measured errors and requires p95
first output within 10 seconds. The report checks input agreement and all lower
tested levels before it assigns a highest passing tested concurrency. This
threshold is a test rule; it does not establish conversational quality.

The saved [comparison data](validation/comparison.json) and
[report](validation/comparison.html) contain two recordings, 128 measured turns,
64 warmup turns, and 32 serial interruption checks. Both frameworks passed the
10-second rule at four simultaneous turns and exceeded it at eight. All measured
turns completed without errors. Detected input and output PCM hashes agreed.
Transcripts and replies matched. These results apply to the listed models, CPU, software sinks,
and closed workload. They do not establish production capacity.

## Deployment checks and further measurements

- Add echo cancellation for microphone use.
- Measure interruption through a real playback device with loopback audio.
- Use sustained loads, more speakers, noise, and real-time input pacing.
- Compare independent Pipecat model engines with equivalent precision and decoding.

## API references

- [Bumblebee audio](https://bumblebee.hexdocs.pm/Bumblebee.Audio.html)
- [Chat completion stream protocol](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events)
- [llama.cpp server](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [Finch streaming](https://hexdocs.pm/finch/Finch.html#stream_while/5)
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
