# Standalone LiveAvatar viewer (#20)

This example invokes the existing `AudioFlow.Avatars.LiveAvatar` LITE publisher
with your supplied **raw mono signed PCM16LE at 24 kHz**, up to 480000 bytes
(10 seconds). The browser uses the real `livekit-client` SDK to subscribe to
**both provider audio and video**. It never plays your PCM separately, captures
microphone/camera, or publishes browser tracks.

From the repository root:

```sh
mix deps.get
cd examples/avatar
npm ci
npm run build
cd ../..
mix run --no-halt examples/avatar/run.exs
```

Open **http://127.0.0.1:4100/**. Default startup makes **no paid provider calls**.
Connect controls, select a `.pcm` file, then Start. Without live configuration,
Start reports a configuration error and does not provision anything. File format
is a caller assertion: this example validates size/sample alignment, not whether
arbitrary raw bytes really contain 24 kHz speech. WAV containers are unsupported.
For example convert a recording with FFmpeg:

```sh
ffmpeg -i speech.wav -t 10 -ac 1 -ar 24000 -f s16le utterance.pcm
```

For live use, set these **only in the server environment**, then restart:

```sh
export AVATAR_LIVE=1
export LIVEAVATAR_API_KEY='your-provider-key'
export LIVEAVATAR_AVATAR_ID='your-available-avatar-id'
mix run --no-halt examples/avatar/run.exs
```

`AVATAR_PORT` optionally changes the loopback port. Do not use `VITE_` variables
for secrets. The endpoint is deliberately local-only: it binds `127.0.0.1`,
rejects other Host headers and requires the exact same browser Origin for its
WebSocket. This is a single-user development example, not a deployment behind a
public proxy. Do not forward its port or expose it publicly; production needs
application authentication, authorization, rate/billing limits and HTTPS/WSS.

Each Start provisions **one new finite session**, not persistent avatar continuity.
The server forwards only the provider's `livekit_client_token` plus room URL;
API key and session bearer stay server-side. Before forwarding, it checks the
provider-issued JWT's expiry and explicit single-room join/subscribe grants,
with publishing/data publishing disabled and no administrative grants. It does
not authenticate arbitrary JWTs or modify/re-sign provider tokens: this token
comes directly from the trusted provider; LiveKit checks the signature. If your
provider issues broader credentials the example **fails closed and stops the
session**. An account with a suitable subscription-only credential is required;
we have not verified the provider's live grants. No agent token is exposed.

The publisher's opt-in `wait_for_viewer: true` gate prevents sending PCM before
both audio and video have subscribed and playback has been enabled (15-second readiness deadline). Existing
publisher callers retain immediate-send behavior. When the room publication arrives, click
**Enable audio / video** to unlock browser autoplay. Retry that button if blocked.
Cancel closes receiver media and requests provider stop; Disconnect and leaving
the page also release the server-owned publisher. Start becomes available after
cleanup to explicitly run another bounded utterance. The publisher bounds work
to 60 seconds plus bounded provider HTTP cleanup. Cancel cannot retract samples
already rendered. Cleanup failure is shown; check the provider dashboard if stop
could not be confirmed. Provider completion is not a browser playout acknowledgement.
A finite session may close before the browser's final buffered media plays.

## Credential-free executable checks

```sh
mix test test/live_avatar_test.exs examples/avatar/server_test.exs
cd examples/avatar
npm ci
npm test
npm run typecheck
npm run build
```

Server fixtures exercise the actual publisher over HTTP/WebSocket, routing,
readiness gating, bounded PCM, explicit repeat, credential withholding,
cancellation/disconnect cleanup and loopback/origin restrictions. Client fixtures
exercise the actual receiver class with SDK event names and track/transport
fixtures: both tracks attach, readiness, detach, playback gesture methods,
subscription/connect errors and idempotent cleanup. Typecheck/build use the
installed real SDK. These are not browser interoperability or live-service tests.

**Unverified without credentials:** live generation and synchronized lip-sync,
acoustic quality, end-to-end latency/playout, account/billing permissions, actual
provider token grants, live remote cleanup and NAT/TURN connectivity. No claim
that #20 is fully resolved or that any avatar continuity exists.

References: [LiveAvatar start session](https://docs.liveavatar.com/api-reference/sessions/start-session),
[LiveKit grants](https://docs.livekit.io/frontends/reference/tokens-grants/),
[SDK subscription/attach/detach and autoplay](https://github.com/livekit/client-sdk-js).
