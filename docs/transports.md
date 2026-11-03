# Network transport integration

The existing `AudioFlow.WebSocket` endpoint remains the raw mono s16le PCM
transport introduced in PR #24. Its wire protocol is unchanged. These additions
wrap its session ownership, output acknowledgements, stale-turn rejection and
VAD path; they do not change Session or history.

## Telephony WebSockets

Mount `AudioFlow.Telephony.WebSocket` in an application-owned Plug:

```elixir
# Authenticate the HTTP upgrade before this point.
WebSockAdapter.upgrade(conn, AudioFlow.Telephony.WebSocket,
  [provider: :twilio, session: session_options,
   vad: {Your16kHzDetector, detector_options}],
  max_frame_size: 100_000)
```

Use real STT/LLM/TTS adapters in `session_options`. The tests use the existing
Demo adapters to test transport behavior, not speech recognition or synthesis.
Install WebSockAdapter and a WebSock-capable server as runtime dependencies in
the host application (this library currently includes them for dev/test only).
Require WSS in deployment. Validate the provider's upgrade signature against the
externally visible URL in the host Plug, before allocating a session; the
WebSock handler cannot authenticate HTTP headers after upgrade. Configure proxy
idle timeouts and application connection limits there as well.

For Twilio, use a bidirectional `<Connect><Stream url="wss://…"/>`, not a
unidirectional `<Start><Stream>`. The handler accepts only mono `audio/x-mulaw`
at 8 kHz, binds `start.streamSid`, and emits `media`/`clear` with that SID.
See [Twilio's message reference](https://www.twilio.com/docs/voice/media-streams/websocket-messages).

For Telnyx, select `provider: :telnyx`, `stream_track: "inbound_track"`,
`stream_bidirectional_mode: "rtp"`, and `stream_bidirectional_codec: "PCMU"`
in the Answer/Dial/streaming_start request. The handler accepts mono PCMU at
8 kHz and binds the top-level `stream_id`. Outgoing messages use Telnyx's
`media` and `clear` envelopes, without a Twilio SID. MP3 playback mode and other
codecs are unsupported. See [Telnyx's streaming guide](https://developers.telnyx.com/docs/voice/programmable-voice/media-streaming).

Both paths decode Base64 headerless μ-law, interpolate to 16 kHz PCM, and feed
the configured VAD. Endpoint detection submits an utterance; confirmed speech
cancels an active reply and clears remote playback. TTS must emit 8 or 16 kHz
mono s16le PCM. Other rates fail the turn and close the stream with code 1011;
configure TTS output or an upstream resampler explicitly. Downsampling uses a
stateful 31-tap FIR, with 15 input samples of delay. On completion the filter
tail is drained and the last 20 ms packet is padded with μ-law silence. No
wideband recovery or production acoustic-quality claim is made.

Input messages are capped at 100 KB and decoded media at 16 KB. Inbound media
must carry positive sequential `media.chunk` values (strings or integers).
Duplicates, gaps, invalid Base64, unsupported formats and mismatched stream IDs
close with code 1008. Outbound-track audio is ignored. **There is no jitter
buffer/reordering implementation**: Telnyx documents that events may arrive out
of order, so this strict ordered-stream path needs a reorder layer before use
on such streams. DTMF and mark acknowledgements are accepted but do not trigger
application actions. Stop or disconnect terminates the owned session.

Acknowledging a chunk means acceptance by the socket handler, not playback at
the handset. The application must bound provider playback latency; pacing,
mark-based playout accounting, SIP, call creation, transfers and webhook
handlers are not provided. No live provider call has been tested.

## RTVI control subset

`AudioFlow.RTVI.WebSocket` can be mounted with the same `:session` options. It
accepts JSON control messages with `label: "rtvi-ai"`, a string `id`, and a
`type`. It negotiates RTVI major version 2 and advertises version `2.0.0`.

```json
{"label":"rtvi-ai","id":"ready-1","type":"client-ready","data":{"version":"2.0.0","about":{"library":"my-client"}}}
{"label":"rtvi-ai","id":"text-1","type":"send-text","data":{"content":"Hello"}}
```

`client-ready` receives a `bot-ready` carrying the same ID. `send-text` runs an
immediate turn with audio, interrupting an active reply. Explicit
`run_immediately: false`, `audio_response: false`, unknown options and unsupported
messages receive an `error-response`; they are not silently treated as supported.
Generated text uses `llm-raw-text`. PCM is sent as Base64 `bot-tts-audio` with
`sample_rate` and `num_channels`. Interruption uses `bot-interrupted`; runtime
turn errors use `error` with `fatal: false`. These shapes follow the official
[RTVI message models](https://github.com/pipecat-ai/pipecat/blob/main/src/pipecat/processors/frameworks/rtvi/models.py)
inspected on 2026-11-03. The loopback tests contain request/response fixtures.

This is an operational text-to-audio endpoint for a **custom transport**, not a
claim that existing Pipecat SDKs can connect unmodified. `bot-tts-audio` is an
RTVI audio event, not a replacement for an SDK media track. There is no
Daily/LiveKit signaling, WebRTC peer connection, Pipecat protobuf WebSocket
media serializer, raw-audio input, context mutation, tool calls, SDK connection
endpoint, or SDK end-to-end conformance test. Those transport-specific contracts
and audio capture/playback integration remain required to satisfy issue #13.

## Issue scope and remaining prerequisites

- #5: raw PCM streaming WebSocket is already supported; this change preserves
  its seven integration tests. WebRTC remains unimplemented: no
  `membrane_webrtc_plugin` dependency, signaling API, ICE/TURN configuration,
  negotiated codecs, or Capture/Player lifecycle exists in this tree.
- #6: this change adds usable PCMU serializers and WebSock session integration,
  with offline codec and loopback tests. Live provider validation, Telnyx
  reordering, call control and SIP remain outstanding; do not close the broad
  telephony issue on these tests alone.
- #13: documented RTVI control subset exists; SDK transport compatibility remains
  outstanding as described above. Leave the issue open.
- #20: blocked, not fixed. Existing `VideoFrameSink` consumes RGB frames for
  inference; it is not a network video output. An avatar integration first needs
  a WebRTC video publishing sink with codec negotiation, frame pacing and
  audio/video timestamps, then an authenticated provider session, generated
  video ingestion, interruption/cleanup handling and real-provider A/V sync tests.
  No avatar provider is simulated or added here.

## Validation

```sh
mix format --check-formatted
mix test
```

Core tests require no native media/ML libraries or provider credentials. Tests
exercise G.711 codewords, resampling chunk continuity and stop-band attenuation,
real loopback WebSocket upgrades for both provider envelopes, PCM session
input/output, barge-in clear, malformed input and stream lifecycle, plus the
RTVI handshake, text/audio events and correlated unsupported-message errors.
They do not establish provider interoperability, SDK conformance or perceived
speech quality.
