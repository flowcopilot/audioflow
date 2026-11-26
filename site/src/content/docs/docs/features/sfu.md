---
title: AudioFlow SFU
description: A BEAM selective forwarding unit for voice agents, with LiveKit client SDK support, telephony and hot upgrades.
---

The AudioFlow SFU (`sfu/`, application `:audio_flow_sfu`) forwards audio
between the members of a room. It runs as its own release on its own nodes,
so agent nodes can restart while calls stay connected. It is built on
[Elixir WebRTC](https://github.com/elixir-webrtc/ex_webrtc) and does not
depend on AudioFlow.

## Members of a room

| Member | How it joins | Media |
| --- | --- | --- |
| Browser or mobile app | LiveKit client SDK at `/rtc/v1`, or the AudioFlow JSON protocol at `/ws` | WebRTC, Opus or PCMU |
| AudioFlow agent | `AudioFlowSFU.Native` over Erlang distribution | RTP fields as Erlang messages, no ICE, DTLS or SRTP |
| Phone call | Twilio or Telnyx Media Streams at `/telephony/twilio` or `/telephony/telnyx` | μ-law; Opus from others is decoded to 8 kHz |

The SFU forwards RTP without transcoding, except toward phone calls. A room
process keeps only the member list; media goes directly between member
processes. If a room process crashes, its members join the restarted room
with the same IDs, and media does not stop.

## LiveKit client SDKs

LiveKit client SDKs connect with a LiveKit URL and token. Tokens are HS256
JWTs with LiveKit claims (`iss` is the API key, `sub` the identity, and the
`video` grant names the room), so LiveKit server SDKs can make them.

| SDK | Version | Checked |
| --- | --- | --- |
| `livekit-client` (JavaScript) | 2.24.0 | join, publish, subscribe, audio, signal resume, leave |
| `livekit` (Python, Rust core) | 1.2.1 | join, publish, subscribe, audio |

The SFU supports the one-connection protocol (`/rtc/v1`). It reports protocol
17, so clients open data channels in-band. Audio only: video, simulcast, data
packets, manual subscription and the LiveKit server APIs are not supported.

## Resume

A participant outlives its signaling socket. It waits for
`away_timeout_ms` (30 s) for the same client or agent to come back: a LiveKit
reconnect, `&resume=<token>` in the JSON protocol, or `Native.join/4` with the
resume token. Media continues while the peer connection is up. An agent that
is away shows as `state: :away`; LiveKit clients see no leave.

## Run it

```sh
cd releases
MIX_ENV=prod mix release audio_flow_sfu
AUDIOFLOW_SFU_PORT=7880 AUDIOFLOW_SFU_API_KEY=key AUDIOFLOW_SFU_API_SECRET=secret \
  _build/prod/rel/audio_flow_sfu/bin/audio_flow_sfu start
```

The release upgrades in place with Castle. `releases/scripts/upgrade_test.sh`
installs a new version during a live call; a local run had no reconnect and a
35 ms longest audio gap.

## Telemetry

`AudioFlowSFU.Telemetry` emits room, participant (join, away, resume, leave)
and track events, and the number of dropped RTP packets.
