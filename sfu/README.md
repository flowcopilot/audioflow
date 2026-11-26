# AudioFlow SFU

A selective forwarding unit for AudioFlow calls, on
[Elixir WebRTC](https://github.com/elixir-webrtc/ex_webrtc). Client media ends
here, not on the agent nodes, so an agent node can restart while the call
stays connected.

This application does not depend on `:audio_flow`. Run it as its own release.

## Model

- A **room** (`AudioFlowSFU.Room`) holds membership only. Media goes directly
  between participant processes.
- A **participant** (`AudioFlowSFU.Participant.WebRTC`) owns one
  `ExWebRTC.PeerConnection` for publish and subscribe. It forwards the RTP of
  its published tracks to its subscribers without transcoding.
- **Tokens** (`AudioFlowSFU.Token`) are HS256 JWTs with LiveKit-compatible
  claims, so LiveKit server SDKs can make them.
- Audio only: Opus and PCMU.

## Signaling

- `AudioFlowSFU.Signaling.JSON` is the AudioFlow protocol v0 at
  `/ws?access_token=<jwt>`. The server makes the first offer. See the module
  documentation for the messages.
- `AudioFlowSFU.Signaling.LiveKit` is the LiveKit client protocol v1 at
  `/rtc/v1` (one peer connection, protobuf messages). LiveKit client SDKs
  connect with a LiveKit URL and token. The server reports protocol 17, so
  clients open data channels in-band. The two-connection path `/rtc` is not
  supported.
- `AudioFlowSFU.Signaling.Telephony` takes Twilio and Telnyx Media Streams
  at `/telephony/twilio` and `/telephony/telnyx`. The phone call joins as a
  participant of kind `sip` with a PCMU track. Opus from the other members is
  decoded at 8 kHz and sent back as μ-law. Twilio passes the token as the
  `access_token` custom parameter of `<Stream>`.
- `AudioFlowSFU.Native` lets BEAM processes, such as AudioFlow agents on
  other nodes, join rooms over Erlang distribution.

A dropped signaling socket does not end the session. The participant waits
for `away_timeout_ms` (30 s) for a resume: `&resume=<token>` in the JSON
protocol, or a LiveKit reconnect with the participant SID.

## LiveKit SDK compatibility

| SDK | Version | Result |
| --- | --- | --- |
| `livekit-client` (JavaScript, headless Chromium) | 2.24.0 | join, publish, subscribe, audio, signal resume, leave |
| `livekit` (Python, Rust core) | 1.2.1 | join, publish, subscribe, audio |

Run `compat/run.sh` to check them. It starts the SFU on port 7880. It needs
Node.js, `uv` and network access for Chromium and the SDK packages.
`scripts/gen_livekit_proto.sh` generates the protocol modules from
livekit/protocol v1.54.2.

## Configuration

```elixir
config :audio_flow_sfu,
  api_keys: %{"my-key" => "my-secret"},
  port: 7880,
  ice_servers: [%{urls: "stun:stun.l.google.com:19302"}],
  max_participants: 100,
  empty_timeout_ms: 30_000
```

## Build and test

`ex_sctp` (WebRTC data channels) is a Rust NIF, so the build needs `cargo`.

```sh
mix deps.get
mix test
```
