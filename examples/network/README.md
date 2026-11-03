# Standalone network publication example

This example does not modify chat or the graph UI. It exercises the encoded
WebRTC prerequisite independently of inference and hardware audio devices.

```sh
AUDIOFLOW_WEBRTC=1 mix deps.get
AUDIOFLOW_WEBRTC=1 mix run examples/network/publish.exs
# Or provide a VP8 IVF file (<=8 MB, <=30 seconds):
AUDIOFLOW_WEBRTC=1 mix run examples/network/publish.exs path/to/video.ivf
```

It negotiates two real local WebRTC peers, trickles host ICE candidates,
completes DTLS, and sends paced PCMU silence plus encoded VP8 frames over SRTP.
The receiver counts audio packets and completed video frames, then both peers
close. Expected bundled-fixture result: **21 PCMU packets, 3 VP8 frames**.
This is a terminal loopback example; it does not display video or open a server.
OpenSSL headers/ABI setup is covered in [the integration guide](../../docs/webrtc-avatars.md).

The included test pattern is generated without user media:

```sh
ffmpeg -f lavfi -i testsrc2=size=160x90:rate=5 -frames:v 3 \
  -c:v libvpx -deadline realtime -f ivf examples/network/assets/test-pattern.ivf
ffmpeg -i examples/network/assets/test-pattern.ivf -f null -
```

To request a real provider-generated avatar publication with your own account:

```sh
# Set LIVEAVATAR_API_KEY and LIVEAVATAR_AVATAR_ID securely in the environment.
mix run examples/network/publish.exs --avatar speech-24k-mono-s16le.pcm
```

The PCM must be <=10 seconds of mono PCM16LE at exactly 24 kHz. This mode
provisions LiveAvatar LITE, submits the utterance only when connected, waits for
its correlated completion and stops the remote session. It deliberately does
not print the private LiveKit subscription token. To view the generated avatar,
integrate the published event into an authenticated app as described below.
No live provider credentials or interoperability were used during validation.

## Contracts for chat and UI integrations

- Start `AudioFlow.WebRTC` with the authenticated connection process as `:owner`.
  Route the returned offer and owner `{:signal, map}` messages to the client.
  Return remote SDP/candidate maps through `signal/2`; never let one user signal
  another user's peer. Authenticate before allocating peer resources.
- Feed an encoded PCMU/VP8 source through `publish/5` with a shared PTS epoch and
  real-time pacing. Use a generation key per turn, `flush/2` on interruption, and
  `stop/1` on disconnect. For PCM use `AudioFlow.WebRTC.Session`, documented below.
- Start `AudioFlow.Avatars.LiveAvatar` with `:owner`, `:api_key`, `:avatar_id` and
  the finite 24 kHz `:audio`. The owner receives
  `{LiveAvatar, publisher, {:published, %{url: url, token: token}}}`. Forward only
  this room-scoped publication descriptor to the authenticated viewer. Subscribe
  to **both** provider tracks with `livekit-client`; a code sample is in the guide.
  Do not simultaneously play the original PCM: the provider's audio is aligned
  with its generated video. The API key and session bearer token stay server-side.
- Surface `{:done, result}` and `{:cleanup, result}` owner events. On disconnect
  or cancel call `LiveAvatar.cancel/1` while the publisher is alive. A failed
  cleanup means the app must not claim the provider session has stopped.

Tests: `mix test test/live_avatar_test.exs test/video_output_ivf_test.exs` for
HTTP/WebSocket fixtures and bounded IVF parsing; `AUDIOFLOW_WEBRTC=1 mix test
test/webrtc_test.exs` for real two-peer negotiation, byte-for-byte RTP reassembly,
clocks, stale-key rejection and peer lifetime cleanup. Provider-generated A/V,
LiveKit subscription, lip-sync, browser autoplay, NAT/TURN and acoustic quality
remain live validation requirements.

## Standalone Session voice agent

```sh
AUDIOFLOW_WEBRTC=1 mix run examples/network/voice_agent.exs
```

This credential-free terminal example sends synthetic voiced PCM plus silence
through a real local WebRTC pair. The Session bridge decodes PCMU, runs an
energy gate through VoiceInput and submits an actual utterance to Session.
**SYNTHETIC DEMO:** Demo adapters return a fixed transcript/reply and silent
16 kHz PCM; they perform no speech inference. The reply is resampled, μ-law
encoded, paced and received as six PCMU packets. No microphone, acoustic,
browser or TURN claim is made. See the guide's PCM Session bridge section for
real adapter integration, explicit signaling routing, supported rates and limits.
