---
title: Network transports
description: Raw PCM WebSocket, Twilio and Telnyx telephony, and the Pipecat RTVI client.
---

The existing `AudioFlow.WebSocket` endpoint remains the raw mono s16le PCM
transport introduced in PR #24. Its wire protocol is unchanged. The telephony
and RTVI endpoints reuse its session ownership, output acknowledgements,
stale-turn rejection and VAD path. Optional WebRTC uses a
separate PCM Session bridge; see [the WebRTC guide](../webrtc-avatars/).

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
must carry positive media.chunk values (strings or integers). Twilio remains
strictly sequential. Telnyx starts at chunk 1 and reorders within a configurable
window (":reorder_window", default 32), with a 64 KB aggregate byte cap
(":reorder_max_bytes"). First buffered copy wins; duplicates and already delivered
chunks are discarded. A missing chunk starts a non-extending 200 ms deadline
(":reorder_timeout_ms"). On timeout or overflow the connection closes with 1008
and discards the buffer; it does not invent silence or splice across a gap.
Malformed payloads and wrong stream IDs also close. Timer tokens prevent stale
timeouts from affecting a recovered stream. Termination cancels timers.

Outgoing PCMU is packetized into 160-byte (20 ms) messages, emitted at most once
per 20 ms timer tick. The local queue defaults to 500 packets (10 seconds),
configurable with :max_playout_packets; overflow closes rather than growing
without bound. Barge-in clears the local queue/filter tail, invalidates its timer,
and sends provider clear immediately. Timers never burst to catch up after delays.
Twilio permits arbitrary payload sizes and buffers media in arrival order;
Telnyx RTP mode permits 20 ms–30 s chunks. The once-per-second submission limit
in Telnyx's guide belongs to MP3 mode, which this transport does not use.

Acknowledging a chunk means local acceptance, not playback at the handset.
Mark-based playout accounting, SIP, call creation/transfers and webhook handlers
remain application work. No live provider call has been tested.

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

A usable [Pipecat JavaScript client sample](https://github.com/flowcopilot/audioflow/blob/main/examples/rtvi-client/README.md)
now supplies an AudioFlow custom Transport subclass against the pinned official
SDK 1.16.0. Its executable test connects the real SDK to this real endpoint,
checks SDK-generated handshake/text, callback dispatch, PCM wire output, errors
and reconnect. Browser playback uses Web Audio with cancellation cleanup.
This does not make Daily/LiveKit/WebRTC or protobuf WebSocket transports work
unmodified. Microphone input, context mutation, tools, other client SDKs and
media-track UI components remain unsupported. Local Demo tests validate wire
behavior, not live inference, browser audio devices or acoustic quality.

## Issue scope and remaining prerequisites

- #5: raw PCM streaming WebSocket and optional ExWebRTC PCMU/VP8 publishing
  plus a PCM Session bridge are implemented. This uses ExWebRTC directly rather
  than the suggested Membrane Live.Capture/Live.Player wrapper. Local peer tests
  cover negotiation and media; browser interoperability, TURN/NAT and production
  loss/congestion handling remain unverified. See the WebRTC guide and
  `examples/network` for setup and limits.
- #6: the requested Twilio/Telnyx PCMU serializer scope is implemented with
  resampling, bounded input reordering, paced output and loopback tests. Live
  carrier validation requires configured accounts/calls and a deployed endpoint.
  SIP and call control were explicitly deferred in the original suggestion;
  they need not block closure of the serializer request.
- #13: official JavaScript SDK works through the supplied custom transport for
  text input and audio output. Rejected ready handshakes propagate the correlated
  server error immediately; unrelated request errors do not reject negotiation.
  Other SDKs, unmodified provider transports and full media/input coverage remain
  outstanding, so broad SDK interoperability is not established.

Avatar publication scope is documented separately in the
[WebRTC and LiveAvatar guide](../webrtc-avatars/).

## Validation

```sh
mix format --check-formatted
mix test
npm --prefix examples/rtvi-client ci
npm --prefix examples/rtvi-client run typecheck
npm --prefix examples/rtvi-client test
```

Core tests require no native media/ML libraries or provider credentials. Tests
exercise G.711 codewords, resampling chunk continuity and stop-band attenuation,
real loopback WebSocket upgrades for both provider envelopes, PCM session
input/output, barge-in clear, malformed input and stream lifecycle, plus the
RTVI handshake, text/audio events and correlated unsupported-message errors.
They do not establish live carrier interoperability, full SDK conformance or
perceived speech quality.

## Standalone examples and application integration contract

Run `MIX_ENV=test mix run examples/telephony-loopback.exs` from the repository
root for an executable Twilio/Telnyx start/media/stop demonstration. Telnyx sends
chunks 2, 2, 1 to exercise initial reordering and duplicate suppression. Both
paths verify six 160-byte outgoing packets over real loopback WebSockets. This
uses an explicitly test-only always-speech detector and silent Demo adapters.
It must not be used as a live-call speech detector.

Applications integrating telephony must mount `AudioFlow.Telephony.WebSocket`
with a provider, real session adapters and a real 16 kHz detector. Authenticate
upgrades in the host Plug, choose the documented bidirectional provider settings,
and configure reorder/playout limits. Call creation, provider secrets and
signature validation belong to the host. The library owns one session per socket;
disconnect releases it. Provider mark acknowledgements are not handset latency
measurements in the current implementation.

For application client views, import `AudioFlowTransport` from the standalone
sample and pass it to official `PipecatClient` with mic/camera disabled. Connect
from a user gesture, call `sendText`, display `onLlmRawText` and message errors,
and disconnect when leaving the view. Audio playback and interruption are
owned by the custom transport; do not attach SDK media-track components.
See the sample README for commands, authentication and unsupported capabilities.
These changes deliberately leave `examples/chat/**` and `ui/**` to their owning
app sessions.
