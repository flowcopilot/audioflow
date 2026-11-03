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
stt = {AudioFlow.Adapters.Deepgram,
  [model: "nova-3", api_key: fn -> System.fetch_env!("DEEPGRAM_API_KEY") end]}

tts = {AudioFlow.Adapters.Cartesia,
  [model: "sonic-3.6", voice_id: System.fetch_env!("CARTESIA_VOICE_ID"),
   api_version: "2026-08-14",
   api_key: fn -> System.fetch_env!("CARTESIA_API_KEY") end]}

# Alternative TTS:
tts = {AudioFlow.Adapters.ElevenLabs,
  [model: "eleven_multilingual_v2", voice_id: System.fetch_env!("ELEVENLABS_VOICE_ID"),
   api_key: fn -> System.fetch_env!("ELEVENLABS_API_KEY") end]}
```

Deepgram uses Listen v1 WebSocket with mono `linear16` PCM at the input
`Audio.sample_rate`, sends bounded binary frames, then `CloseStream`. It emits
only final transcript segments, separated by spaces; the concluding Metadata
message completes the run. Interim results are ignored. This is a streaming
provider response for an already committed utterance, **not** microphone-to-STT
live ingress or a persistent recognition session. Optional `:language` is sent
as a query parameter. Empty final transcripts (silence) emit nothing.

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

**Integration gap for #8:** these mixed-output callbacks cannot be put into the
existing Session `:stt`, `:llm`, or `:tts` slots: each slot validates one output
type and the session runs a chained pipeline. No Session, graph, UI, or history
routing has been changed. A future speech-to-speech session mode must route
these events, persist conversation context, and coordinate playback truncation.
Direct calls open a fresh connection per turn and do not retain provider
history. There is no continuous duplex input, tool execution, resampling,
WebRTC, automatic reconnect, or cross-turn provider state.

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

Wire shapes were checked against official documentation on 2026-11-03:

- [OpenAI Realtime conversations](https://developers.openai.com/api/docs/guides/realtime-conversations)
- [Gemini Live WebSocket reference](https://ai.google.dev/api/live)
- [Deepgram Listen streaming reference](https://developers.deepgram.com/reference/speech-to-text/listen-streaming)
- [Cartesia bytes TTS](https://docs.cartesia.ai/api-reference/tts/bytes)
- [ElevenLabs streaming TTS](https://elevenlabs.io/docs/api-reference/text-to-speech/stream)

`mix test test/remote_providers_test.exs` exercises local protocol fixtures,
setup ordering, authentication/request shapes, final/delta event mapping,
streaming before EOF, odd PCM chunk boundaries, errors, limits, timeouts and
connection cleanup on caller cancellation. It performs no model inference.
