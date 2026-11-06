# Remote speech providers

These adapters make real network requests. The regression suite uses local HTTP
and WebSocket fixtures; it does **not** establish provider account access, model
availability, latency, recognition accuracy, or acoustic quality. No live
credential tests have been run.

## Session-compatible STT and TTS

Use these tuples in existing `:stt` and `:tts` session options (or graph stages
accepting the same types). Model and voice IDs must be available to your account.
Keys may be strings or zero-argument functions; functions allow runtime rotation.

```elixir
stt = {AudioFlow.STT.ReqLLM,
  [model: "deepgram:nova-3", api_key: fn -> System.fetch_env!("DEEPGRAM_API_KEY") end]}

tts = {AudioFlow.Adapters.Cartesia,
  [model: "sonic-3.6", voice_id: System.fetch_env!("CARTESIA_VOICE_ID"),
   api_version: "2026-08-14",
   api_key: fn -> System.fetch_env!("CARTESIA_API_KEY") end]}

# Alternative TTS:
tts = {AudioFlow.Adapters.ElevenLabs,
  [model: "eleven_multilingual_v2", voice_id: System.fetch_env!("ELEVENLABS_VOICE_ID"),
   api_key: fn -> System.fetch_env!("ELEVENLABS_API_KEY") end]}
```

All speech-to-text from external services goes through ReqLLM with
`AudioFlow.STT.ReqLLM`, for Mistral Voxtral, Deepgram, OpenAI, Groq, ElevenLabs,
OpenRouter and self-hosted vLLM servers. See the common STT interface in the
[README](https://github.com/flowcopilot/audioflow#transcription). ReqLLM has no
Deepgram provider, so AudioFlow registers `AudioFlow.STT.DeepgramProvider`.
It sends the utterance as one WAV body to the pre-recorded `POST /v1/listen`
API, with `model`, optional `language` and `:provider_options` as query
parameters. With `segments: true`, it requests `utterances=true` and emits each
utterance as a timed segment. Deepgram interim results are not used.

Cartesia uses `/tts/bytes` and ElevenLabs uses `/text-to-speech/:voice_id/stream`.
Both stream raw signed 16-bit little-endian mono PCM as `AudioFlow.Audio`, default
24 kHz, while the HTTP response is arriving. They buffer only an incomplete
sample when HTTP chunks split a 16-bit value. Optional `:sample_rate` supports
8000, 16000, 22050, 24000, 44100 and 48000 (account restrictions may apply).
Optional `:language` maps to the provider's language field. Cartesia requires an
explicit `:api_version`; the request schema here follows `2026-08-14` (voice ID
string). Older Cartesia schemas are not supported. These are text-in/audio-out
HTTP streams, not bidirectional text WebSocket streams. MP3, WAV and μ-law are
not decoded and are not requested.

## Direct speech-to-speech calls

These calls send one committed utterance per connection. For an always-on
OpenAI conversation with the microphone open, use
[`AudioFlow.Duplex.OpenAIRealtime`](#continuous-openai-realtime-conversation).

`AudioFlow.Adapters.OpenAIRealtime.run/3` and
`AudioFlow.Adapters.GeminiLive.run/3` accept a committed `AudioFlow.Audio` and
invoke an arity-one callback with `{:transcript, text}`, `{:text, delta}` and
`{:audio, %AudioFlow.Audio{}}` values. The callback must return `:ok`. Return is
`:ok` or `{:error, reason}`. Input transcription can arrive after generated
speech. Gemini transcripts and assistant text are deltas; concatenate in order.
OpenAI emits one completed input transcript and assistant text deltas.

```elixir
AudioFlow.Adapters.OpenAIRealtime.run(audio_24khz,
  [model: System.fetch_env!("OPENAI_REALTIME_MODEL"),
   api_key: fn -> System.fetch_env!("OPENAI_API_KEY") end,
   instructions: "Answer briefly.", voice: "marin"],
  fn event -> send(output_process, event); :ok end)

AudioFlow.Adapters.GeminiLive.run(audio_16khz,
  [model: System.fetch_env!("GEMINI_LIVE_MODEL"), # include models/ prefix
   api_key: fn -> System.fetch_env!("GEMINI_API_KEY") end],
  fn event -> send(output_process, event); :ok end)
```

OpenAI uses the GA Realtime WebSocket protocol, waits for `session.updated`,
disables VAD, appends and commits the input, then requests a response. Input and
output PCM must be 24 kHz. Input transcription defaults to
`gpt-4o-mini-transcribe` (`:transcription_model` overrides it). Success waits for
both a completed response and input transcription. Failed or cancelled
responses, transcription failures and tool calls return errors.

Gemini uses Live v1beta, waits for `setupComplete`, disables automatic activity
detection and wraps the audio in `activityStart` / `activityEnd`. Input is
16 kHz PCM, output is 24 kHz PCM. It requests input/output transcription.
`turnComplete` ends the run; interruptions, tool calls and `goAway` fail the
run. Both adapters support optional `:instructions`.

## Session speech-to-speech mode

Start a dedicated Session without dummy STT/LLM/TTS adapters:

```elixir
{:ok, session} = AudioFlow.start_session(
  speech_to_speech: {AudioFlow.Adapters.OpenAIRealtime,
    [model: System.fetch_env!("OPENAI_REALTIME_MODEL"),
     api_key: fn -> System.fetch_env!("OPENAI_API_KEY") end,
     instructions: "Answer briefly."]},
  timeout_ms: 30_000, max_input_bytes: 960_000,
  max_events: 1024, max_output_bytes: 16_777_216)
{:ok, turn} = AudioFlow.submit(session, audio_24khz)
# Receive {AudioFlow, session, turn, {:transcript | :text | :audio, value}}
# followed by {:done, metrics} or {:error, reason, metrics}.
AudioFlow.cancel(session)
AudioFlow.stop_session(session)
```

GeminiLive uses the same option with 16 kHz input. Only committed PCM inputs
are accepted. One active turn is allowed; busy input is rejected. The optional
Output transport receives start/push/finish and flush on cancellation or failure.
Cancellation, timeout, owner exit and stop terminate the socket-owning task.
Late callbacks for an old turn are rejected. The byte budget counts cumulative
text/transcript UTF-8 and PCM payload bytes, separately from event count. The
owner must still consume its mailbox across turns. Provider limits also apply.

This mode explicitly rejects `:history`, stage adapters, graph plans and
conversation flows. Each turn opens a fresh connection; no prior transcript is
silently substituted for native provider context. Instructions are supported as
provider options, but replaying prior text/audio, native item truncation, session
resumption and provider history are not implemented. No heard-text checkpoints
are inferred from mixed deltas: their ordering and boundaries do not establish
text/audio alignment. Acknowledgements can track PCM progress but cannot prove
which transcript prefix was heard. The official [OpenAI conversation guide](https://developers.openai.com/api/docs/guides/realtime-conversations#interruption-and-truncation)
also distinguishes native audio truncation from a precisely truncated transcript.
[Gemini session management](https://aistudio.google.com/docs/live-api/session-management)
describes persistent connections and explicit resumption handles; this adapter
does not retain or replay those handles.

Graph/UI registration remains deferred: the current catalog and edge validator
expose one typed output per stage. A useful mixed-output speech node needs
explicit typed event ports (transcript, text and audio), routing/validation for
each, and a dedicated history capability contract. Registering either adapter
as an existing STT/LLM/TTS node would misrepresent its contract. Use the explicit
Session mode or direct API today. There is no continuous duplex input, tool
execution, automatic reconnect, resampling or WebRTC in this mode. For
continuous input, see `AudioFlow.Duplex` below.

## Local Moshi speech-to-speech

`AudioFlow.Adapters.Moshi` runs one committed turn against a local
[Kyutai Moshi](https://github.com/kyutai-labs/moshi) server. Moshi is a 7B
full-duplex model. The 4-bit MLX build needs approximately 5 GB of weights and
runs on an Apple Silicon laptop. The adapter needs `AUDIOFLOW_MEDIA=1`, because
it uses `membrane_opus_plugin` for Opus and `membrane_ogg_plugin` for Ogg pages.

Start the server (Python 3.12, approximately 5 GB download on first start):

```sh
uvx --python 3.12 --from moshi_mlx python -m moshi_mlx.local_web \
  -q 4 --hf-repo kyutai/moshika-mlx-q4 --no-browser --port 8998
```

Use the adapter with 24 kHz input:

```elixir
{:ok, session} = AudioFlow.start_session(
  speech_to_speech: {AudioFlow.Adapters.Moshi, [endpoint: "ws://127.0.0.1:8998/api/chat"]},
  timeout_ms: 60_000)
```

The wire protocol is binary WebSocket messages with a one-byte kind: `0`
handshake, `1` Ogg Opus audio (24 kHz mono), `2` UTF-8 text tokens. The adapter
sends the input as 80 ms Ogg pages of four 20 ms Opus packets, then silence. It
sends one silent frame for each output frame, so the model sets the pace, not
the wall clock. Output for the input period is dropped.

Moshi has no end-of-turn signal. The reply ends after `:end_silence_ms` (1,600)
of model output without a text token. The turn fails with `:no_reply` if
`:max_reply_ms` (20,000) passes without text. The default `:timeout_ms` is
60,000. Moshi does not transcribe the user, so there is no `:transcript` event.

Limits:

- The server serves one connection at a time. A second turn waits for the lock.
- Model state continues across connections. The server does not reset context
  between turns, and the adapter cannot clear it.
- The first turn after server start is slow (approximately 13 s on an M5) while
  MLX warms up. Later turns gave the first reply audio approximately 2 s after
  submit for a 3.2 s question.
- Moshi speaks English only.
- The adapter calls the Opus `Native` modules and the Ogg `Page`, `Parser` and
  `Opus` modules directly, not through Membrane pipeline elements. The
  `Membrane.Ogg.Muxer` element holds packets until a page has 255 segments
  (approximately 5 s), which is too slow for a duplex model. These modules are
  internal to the plugins, so the dependencies are pinned to `~> 0.21.0` and
  `~> 0.5.2`.

To check a running server, convert a question to raw 24 kHz PCM and run:

```sh
AUDIOFLOW_MEDIA=1 AUDIOFLOW_HTTP_MODEL_TESTS=1 \
AUDIOFLOW_MOSHI_PCM=question.s16le mix test test/moshi_test.exs
```

`AUDIOFLOW_MOSHI_ENDPOINT` overrides the default endpoint.

### Continuous full-duplex Moshi

`AudioFlow.Duplex` keeps one Moshi connection open. Microphone input and model
output flow at the same time. There is no committed turn, no end-of-turn
detection, no silence gate, and no output drop while the user speaks. Use it
for a live conversation. Use `AudioFlow.Adapters.Moshi` for one committed turn.

```elixir
{:ok, duplex} =
  AudioFlow.Duplex.start_link(
    owner: self(),
    adapter: {AudioFlow.Duplex.Moshi, endpoint: "ws://127.0.0.1:8998/api/chat"})

# Wait for {AudioFlow.Duplex, ^duplex, :ready}, then push 80 ms chunks:
:ok = AudioFlow.Duplex.push(duplex, %AudioFlow.Audio{data: pcm_3840_bytes, sample_rate: 24_000})
:ok = AudioFlow.Duplex.stop(duplex)
```

`start_link/1` returns before the connection opens. The owner receives
`{AudioFlow.Duplex, pid, event}`, where `event` is `:ready` (after the Moshi
handshake), `{:audio, %AudioFlow.Audio{}}`, `{:text, token}`,
`{:error, reason}` or `:closed`. `:closed` comes last, also after an error.
`push/2` returns `{:error, :not_ready}` before `:ready` and `{:error, :closed}`
after the session stops. Keep the endpoint in server configuration; the browser
does not need it.

`start/1` starts an unlinked session with the same API. Use it when the owner
must also survive an unexpected adapter crash, as the chat UI does. Monitor
the returned process to detect these crashes. Both start functions monitor
the owner and close the connection when it exits.

The adapter sends each complete 80 ms frame (3,840 bytes at 24 kHz) as one Ogg
page at once. A shorter remainder waits for the next push. Moshi answers each
input frame with one output frame, so the client must push continuous audio,
silence included, to get continuous output.

Bounds (defaults):

- `:connect_timeout_ms` (15,000) from start to the Moshi handshake.
- `:idle_timeout_ms` (30,000) without an accepted push.
- `:max_session_ms` (1,800,000) in total.
- `:max_chunk_bytes` (48,000) for each push, else `{:error, :too_large}`.
- `:max_response_bytes` (67,108,864) for all incoming WebSocket bytes in a
  session, including fragments. The session fails with `:response_too_large`
  at this bound. Incomplete Ogg packets are limited to 256 KiB.
- `:max_input_lead_ms` (2,000). For Moshi (adapter input flow `:answered`):
  pushed audio that model audio has not answered. For OpenAI (`:realtime`):
  pushed audio ahead of the wall clock since `:ready`, so continuous silence
  never fills it. A push past it returns `{:error, :overloaded}` and is not
  sent, for example while MLX warms up.
- `:max_owner_queue` (250): when the owner mailbox has this many messages, the
  session fails with `:owner_overloaded`. Output is not buffered or dropped.
- `:send_timeout_ms` (5,000) for each TCP write.

The session monitors the owner and closes the connection when the owner exits.
On failure, timeout and `stop/1` it exits with reason `:normal`, so the link
from `start_link/1` does not stop the owner. The owner must be a local process.
The Moshi server limits above also apply: one connection at a time, and model
state continues across connections.

`mix test test/duplex_test.exs` (with `AUDIOFLOW_MEDIA=1`) checks simultaneous
input and output, frame sizes, the handshake gate, the input and owner bounds,
timeouts and connection cleanup against a local fixture. With
`AUDIOFLOW_HTTP_MODEL_TESTS=1` and `AUDIOFLOW_MOSHI_PCM`, it also streams the
question and then silence in real time to a running server.

### Continuous OpenAI Realtime conversation

`AudioFlow.Duplex.OpenAIRealtime` keeps one authenticated OpenAI Realtime GA
WebSocket open for a whole conversation. It needs no media build.

```elixir
{:ok, duplex} =
  AudioFlow.Duplex.start(
    owner: self(),
    adapter:
      {AudioFlow.Duplex.OpenAIRealtime,
       model: System.fetch_env!("OPENAI_REALTIME_MODEL"),
       api_key: fn -> System.fetch_env!("OPENAI_API_KEY") end,
       voice: "marin"})

# After {AudioFlow.Duplex, ^duplex, :ready}, push 24 kHz PCM continuously,
# silence included:
:ok = AudioFlow.Duplex.push(duplex, %AudioFlow.Audio{data: pcm, sample_rate: 24_000})
```

The adapter sends `session.update` (type `realtime`, `output_modalities`
`["audio"]`, PCM 24 kHz in and out, the voice, input transcription and
`server_vad` with `create_response` and `interrupt_response`) after
`session.created`, and emits `:ready` after `session.updated`. Each push is one
`input_audio_buffer.append`. The adapter never commits input and never sends
`response.create`: OpenAI detects each utterance, replies to it and cancels the
reply when new speech starts. All utterances of one connection share the
provider conversation; a new connection starts a new one. The API key function
runs only to connect, so the key is not kept in the session state. Options:
`:model`, `:api_key`, `:voice` (`"marin"`), `:instructions` (`""`),
`:transcription_model` (`"gpt-4o-mini-transcribe"`) and `:endpoint`.

The owner also receives:

| Event | Meaning |
| --- | --- |
| `{:speech_started, item}` | User speech started. Flush queued reply audio; keep the microphone open. Late audio and text of the interrupted reply are dropped. |
| `{:transcript, item, text \| :failed}` | Final transcript of the user utterance `item`. |
| `{:response, id, status}` | Reply `id` was `:created`, or ended `:completed`, `:cancelled`, `:incomplete` or `:failed`. |
| `{:output, item}` | The next `{:audio, _}` events belong to reply audio `item`. |

After a flush, report the played part of the cut reply with
`AudioFlow.Duplex.control(duplex, {:played, item, ms})`. If `ms` is less than
the audio received for `item`, the adapter sends `conversation.item.truncate`
(`audio_end_ms` capped to the received audio), so the provider history keeps
only the played audio and its transcript. Only the last interrupted reply is
accepted, once; other reports return `{:error, :stale}` and leave the call
open. A rejected truncation also leaves the call open. The played time is
client playback time: it does not prove acoustic delivery. Without a report,
the provider history keeps the full reply.

Provider `error` events fail the session with `{:remote_error, code}` (only
the code or type, never the message). Tool calls fail it with
`:unsupported_tool_call`, because no tools are configured. All
`AudioFlow.Duplex` bounds apply; `:max_response_bytes` (64 MiB) is about 17
minutes of base64 reply audio per session.
The chat example sets this bound to 256 MiB for OpenAI calls, to allow the
30-minute call limit to apply before the response byte limit in ordinary use.

`mix test test/duplex_openai_test.exs` checks the handshake order, server VAD
configuration, several utterances on one socket, continuous silence,
interruption drops, truncation bounds, provider errors and cleanup against a
local WebSocket peer, not OpenAI.

## Bounds, cancellation and errors

All providers accept `:endpoint` overrides for proxies and local tests. Use
HTTPS/WSS for credentials on external networks. Requests are not redirected or
retried. Provider errors are normalized without returning credential-bearing
URLs or provider message contents. Partial output may have been emitted before
an error; callers must decide whether to discard it.

WebSocket operations have a total `:timeout_ms` budget (30,000 default, including
time spent in the callback) and `:max_response_bytes` (16,777,216, before
WebSocket decoding). Input must be nonempty valid PCM, at most 2 MB, at the
provider's exact rate for Realtime/Gemini. Pings get pongs. Premature socket
closure fails the run. The calling turn process owns the socket; terminating
it closes the connection and stops remote generation on that connection. There
is no separate cancel handle or in-connection `response.cancel` command.

HTTP TTS accepts `:timeout_ms` (30,000), `:receive_timeout_ms` (10,000),
`:max_request_bytes` (65,536), and `:max_response_bytes` (16,777,216).
The Finch read budget excludes callback backpressure; use a Session/worker
deadline to bound the complete operation. Killing the turn releases the HTTP
connection. Empty responses, unsupported content types, and incomplete final
samples fail. Limits and timeout options must be positive integers.

## Protocol references and verification

Wire shapes were checked against official documentation on 2026-11-03
(OpenAI Realtime events again on 2026-11-06):

- [OpenAI Realtime conversations](https://developers.openai.com/api/docs/guides/realtime-conversations)
- [OpenAI Realtime WebSocket](https://developers.openai.com/api/docs/guides/voice-websockets),
  [voice activity detection](https://developers.openai.com/api/docs/guides/realtime-vad),
  [client events](https://developers.openai.com/api/reference/resources/realtime/client-events) and
  [server events](https://developers.openai.com/api/reference/resources/realtime/server-events)
- [Gemini Live WebSocket reference](https://ai.google.dev/api/live)
- [Deepgram pre-recorded utterances](https://developers.deepgram.com/docs/utterances)
- [Cartesia bytes TTS](https://docs.cartesia.ai/api-reference/tts/bytes)
- [ElevenLabs streaming TTS](https://elevenlabs.io/docs/api-reference/text-to-speech/stream)

`mix test test/remote_providers_test.exs` exercises local protocol fixtures,
setup ordering, authentication/request shapes, final/delta event mapping,
streaming before EOF, odd PCM chunk boundaries, errors, limits, timeouts and
connection cleanup on caller cancellation. It performs no model inference.
