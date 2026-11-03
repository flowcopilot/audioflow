# Pipecat JavaScript client with AudioFlow custom transport

This maintained-in-repo `Transport` subclass targets the official
`@pipecat-ai/client-js` **1.16.0**, pinned with a lockfile. It carries typed text,
RTVI control events and base64 mono s16le audio over AudioFlow's RTVI WebSocket.
It implements the SDK's initialization, ready handshake, connection state,
disconnect, and reconnection contracts. A rejected ready handshake reports the
correlated server error immediately and releases its readiness timer. The browser schedules PCM via Web Audio,
stops queued sources on interruption/disconnect, and limits queued playback to
10 seconds. Connect from a click to permit audio playback.

This is **custom transport compatibility**, not unmodified Daily, LiveKit,
SmallWebRTC or Pipecat protobuf WebSocket transport compatibility. Microphone,
camera and screen share are explicitly unsupported. `tracks()` has no media
tracks; audio is played by this transport, not SDK media-track components.
`bot-tts-audio` is consumed for playback here; the SDK may log it as an unknown
control event. No speech quality or live inference claim follows from Demo PCM.

## Run

From this directory: `npm ci`, then `npm run sample`. Enter the WSS URL of a
host-mounted `AudioFlow.RTVI.WebSocket` endpoint (see `docs/transports.md`). Use
host-owned session adapters and authenticate the HTTP upgrade before allocating
a session. Browser WebSocket uses cookies or another host-authorized mechanism;
it cannot set arbitrary authentication headers. The Vite page is a development
sample; configure host origin/cookie policy for deployment.

For an offline Demo endpoint, from the repository root:
`MIX_ENV=test mix run --no-halt examples/rtvi-client/server.exs`.
It prints a loopback port to enter in the page. Demo returns silent PCM.

## Validate

From the repository root, after `mix deps.get`:

```
npm --prefix examples/rtvi-client ci
npm --prefix examples/rtvi-client run typecheck
npm --prefix examples/rtvi-client test
```

The executable test launches a real Bandit/AudioFlow server and uses the actual
SDK `PipecatClient`, SDK-generated `client-ready` and `sendText`, SDK callback
dispatch, error correlation, limits, disconnect and reconnect. Node supplies
browser user-agent metadata and `ws`; this is a protocol test, not a browser
speaker/acoustic test. No credentials or external inference services are used.

Upstream contracts inspected 2026-11-03:
[Transport interface](https://github.com/pipecat-ai/pipecat-client-web/blob/main/client-js/client/transport.ts),
[client lifecycle and callbacks](https://github.com/pipecat-ai/pipecat-client-web/blob/main/client-js/client/client.ts).
Run typecheck and conformance tests when updating the pinned SDK.
