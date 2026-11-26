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

`AudioFlowSFU.Signaling.JSON` is the AudioFlow protocol v0 at
`/ws?access_token=<jwt>`. The server makes the first offer. See the module
documentation for the messages.

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
