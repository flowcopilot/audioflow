# Optional encoded WebRTC and LiveAvatar publishing

This adds partial implementations for #5 and #20. Neither issue is claimed fully
resolved. The existing raw PCM WebSocket transport remains the Session path.

## Encoded WebRTC audio/video output prerequisite

Set `AUDIOFLOW_WEBRTC=1` for both dependency resolution and execution:

```sh
AUDIOFLOW_WEBRTC=1 mix deps.get
AUDIOFLOW_WEBRTC=1 mix test test/webrtc_test.exs
```

ExWebRTC 0.18 requires OpenSSL development headers, a C compiler and pkg-config.
Its SRTP dependency can download a native precompiled library. These are absent
from the default core dependency graph; `AUDIOFLOW_MEDIA` and `AUDIOFLOW_ML` are
independent. OpenSSL must match the major/minor ABI already loaded by Erlang.
This host uses OpenSSL 3.5.9 in Erlang; a temporary shell with OpenSSL 3.6.5
compiled successfully but could not load the DTLS NIF. The successful local
build used the already installed matching development package:

```sh
PKG_CONFIG_PATH=/nix/store/wps4g7kaj73d2zs53a5cfimw1bnb3c99-openssl-3.5.9-dev/lib/pkgconfig \
  AUDIOFLOW_WEBRTC=1 MIX_ENV=test mix deps.compile ex_dtls --force
AUDIOFLOW_WEBRTC=1 mix test test/webrtc_test.exs test/live_avatar_test.exs
```

The current Membrane dependencies implement file/camera decoding and PortAudio;
they do not include WebRTC. We inspected
[Membrane WebRTC 0.26.8](https://hexdocs.pm/membrane_webrtc_plugin/readme.html),
which wraps ExWebRTC, and use
[ExWebRTC 0.18](https://hexdocs.pm/ex_webrtc/ExWebRTC.PeerConnection.html)
directly to avoid pulling file/camera/PortAudio native plugins into a network
peer. This is not a `Membrane.WebRTC.Live.Player` or `Live.Capture` wrapper.

```elixir
{:ok, peer} = AudioFlow.WebRTC.start_link(owner: self(),
  ice_servers: [%{urls: "turn:turn.example.org", username: user, credential: secret}])
{:ok, offer} = AudioFlow.WebRTC.offer(peer)
# Send offer over your authenticated signaling connection.
# Pass remote {"type":"answer","sdp":"..."} maps to signal/2.
# Relay {AudioFlow.WebRTC, peer, {:signal, message}} to the remote peer.
# Candidates use {"type":"candidate","candidate": browserCandidate.toJSON()}.
# Incoming offers automatically emit an answer through the same owner event.

key = make_ref()
:ok = AudioFlow.WebRTC.start_turn(peer, key)
:ok = AudioFlow.WebRTC.publish(peer, key, :audio, encoded_pcmu_160_bytes, 20_000)
:ok = AudioFlow.WebRTC.publish(peer, key, :video, encoded_vp8_frame, 20_000)
:ok = AudioFlow.WebRTC.flush(peer, key)
AudioFlow.WebRTC.stop(peer)
```

Both outgoing tracks are created before negotiation. Audio is PCMU mono at
8 kHz, exactly 160 encoded bytes per 20 ms call. Video is VP8 at 90 kHz; frames
are fragmented into <=1200 byte RTP payloads with RFC 7741 start and last-packet
marker bits. Sequence numbers and 32-bit clock wrapping are maintained. PTS is
in microseconds on a shared epoch for the entire peer lifetime, monotonic per
track even across turns. The producer must pace frames; a timestamp is not a
scheduler. ExWebRTC handles ICE/DTLS/SRTP and RTCP, and forwards received track,
RTP and RTCP notifications to the owner as `{:media, event}`. An application must
consume these notifications promptly. A peer closes after a 15-second negotiation
deadline, failed connection, owner death or explicit stop.

Local tests negotiate two real peers over host ICE and DTLS/SRTP and check
received packet payloads, clocks, fragmentation, cancellation keys and cleanup.
The VP8 fixture is a generated FFmpeg test pattern, and the test reassembles
its first encoded keyframe byte-for-byte after RTP reception. FFmpeg independently
decodes all three fixture frames locally; this is not browser interoperability.
Remaining: PCM encoder/decoder integration with Session/VAD, browser signaling
route/authentication, real-time scheduler, jitter/receiver buffering, congestion
adaptation, acoustic tests, browser interoperability and TURN/NAT deployment
validation. Flush rejects future stale-key calls; it cannot remove RTP already
accepted by ExWebRTC or rendered remotely. RTP acceptance is not playout ack.

## LiveAvatar finite-utterance publication

The adapter uses maintained LiveAvatar LITE, not the sunset HeyGen Streaming
Avatar API. Protocol references checked on 2026-11-03:

- [Create session token](https://docs.liveavatar.com/api-reference/sessions/create-session-token)
- [Start session](https://docs.liveavatar.com/api-reference/sessions/start-session)
- [LITE events](https://docs.liveavatar.com/docs/lite-mode/events)
- [Stop session](https://docs.liveavatar.com/api-reference/sessions/stop-session)

```elixir
{:ok, publisher} = AudioFlow.Avatars.LiveAvatar.start_link(
  owner: self(), api_key: fn -> System.fetch_env!("LIVEAVATAR_API_KEY") end,
  avatar_id: avatar_id,
  audio: %AudioFlow.Audio{data: pcm, sample_rate: 24_000})
# Receives {LiveAvatar, publisher, {:published, %{url: livekit_url, token: token}}}
# Subscribe an authorized LiveKit client to the room's audio AND video tracks.
# The provider generates and publishes the synchronized tracks; do not also play PCM.
# Receives {:done, :ok | {:error, reason}} then {:cleanup, result} in that envelope.
AudioFlow.Avatars.LiveAvatar.cancel(publisher)
```

One publisher creates one session for one finite utterance of at most ten seconds
of mono PCM16LE at 24 kHz. It waits for the media socket's connected event before
sending <=one-second base64 chunks, then seals the utterance with `speak_end`.
The UUID correlates completion events; unrelated completion cannot end the turn.
A 60-second deadline bounds media work. Cancellation kills the caller-owned
socket worker and requests remote session stop. Owner exit and provider errors
also clean up. Cleanup failures are reported; remote termination cannot be
promised when the service is unavailable. Tokens are never logged by the module;
keep owner events private. `:endpoint` exists for local HTTP fixtures.

The local fixture verifies real HTTP and WebSocket exchange, PCM chunking,
readiness, correlation, completion and cancellation cleanup. **No credentials
were available:** actual avatar availability, account billing/permissions,
LiveKit subscription, generated A/V, lip-sync, end-to-end latency and live remote
cleanup remain unverified. This implementation requests actual provider A/V
publication; it does not implement a LiveKit receiver/relay into the separate
ExWebRTC peer, continuous multi-turn Session output or local avatar rendering.
Use a LiveKit client in the host application to receive the provider tracks.

For example, a host application's JavaScript client with the optional
`livekit-client` package can subscribe to the returned publication:

```javascript
import {Room, RoomEvent} from "livekit-client";
const room = new Room();
room.on(RoomEvent.TrackSubscribed, (track) => {
  // Attach both audio and video, preserving LiveKit's synchronized playout.
  document.querySelector("#avatar").append(track.attach());
});
await room.connect(publication.url, publication.token);
await room.startAudio(); // call from a user gesture if autoplay is blocked
// On leaving the view: await room.disconnect(); cancel the server publisher too.
```
