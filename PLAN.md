# Plan: Durable voice agent calls (AudioFlow SFU, hot upgrades, call rejoin)

## Goal

Make AudioFlow the best way to build voice agents on the BEAM. The first step
is durable calls: a call must stay connected when an agent node is deployed,
restarted or crashes. The agent must rejoin the call and continue with the
same history and conversation state. To get this, client media must end in a
media server that is separate from the agent nodes (as Cloudflare Realtime
does for Octoroom). We build that media server ourselves, as a BEAM SFU
(`audio_flow_sfu`) on `ex_webrtc`. It speaks our own JSON signaling protocol
and the LiveKit client protocol, so the LiveKit client SDKs can connect to
it. All releases support hot code upgrades, as Erlang telephony systems do,
so most deployments do not restart a node.

## Approach

### Inspiration

| Source | What we take |
| --- | --- |
| Cloudflare Realtime / Octoroom | Media ends outside the agent server. Agent workers rejoin the call after a restart. |
| LiveKit | Rooms, participants and tracks. The client signal protocol (so its client SDKs work). JWT access tokens with a `video` grant. Agent dispatch (a job per call) and drain on deploy. Client resume after a network change. |
| Erlang/OTP telephony | Hot code upgrades with appups and relups (Castle and Forecastle). `code_change/3` on every stateful process. |
| Pipecat | Pluggable transports and the RTVI client protocol (AudioFlow already has `AudioFlow.RTVI.WebSocket`). |
| Elixir WebRTC "Nexus", Fishjam / Membrane RTC Engine | SFU design on `ExWebRTC.PeerConnection.send_rtp/4`, which rewrites SSRC and payload types. |

### Architecture

```text
browser / mobile / phone              audio_flow_sfu (SFU nodes)               agent nodes (host release)
  AudioFlow JSON signaling ───┐
  LiveKit client SDK (/rtc) ──┼──▶  Signaling ─▶ Room ─ Participant.WebRTC    AudioFlow.Calls.Call
  Twilio/Telnyx WS (PCMU) ────┘                      ─ Participant.Telephony    ├─ AudioFlow.SFU.Participant
                                                     ─ Participant.Native ◀────┤   (Erlang dist, RTP terms)
                                                                                └─ AudioFlow.Session
                                                                                         │
                                                                                AudioFlow.CallStore (Postgres)
```

### Repository layout

Everything stays in this repository. A full umbrella does not fit the
current root project: umbrella children must share one `build_path`, but
the root `mix.exs` selects `_build/<profile>` from the `AUDIOFLOW_*` flags.
Moving the library to `apps/audio_flow` would also break the `path: ".."`
dependencies of `ui/` and `examples/chat`. So we use a "poncho" layout. It
gives the umbrella result (one place that builds all releases) without
moving the library:

```text
mix.exs          :audio_flow       library (unchanged location, flags unchanged)
sfu/mix.exs      :audio_flow_sfu   SFU application, no dependency on :audio_flow
releases/mix.exs :audio_flow_releases
                 path deps on .. and ../sfu
                 releases: audio_flow_sfu  (SFU only, the production artifact)
                           audio_flow_dev  (SFU + AudioFlow + demo agent on one node, not durable)
ui/              unchanged
```

Agent releases contain user code, so users build them in their own
projects. The `audio_flow_dev` release and `examples/durable-call/` show how.

### Key design decisions

1. **The SFU is a separate application and release.** If the SFU runs in the
   agent node, an agent restart drops the media too. `:audio_flow_sfu` does
   **not** depend on `:audio_flow`. A small SFU changes rarely and is easy to
   hot-upgrade.
2. **Two signaling protocols on one core.** `AudioFlowSFU.Signaling.JSON`
   (our protocol v0) and `AudioFlowSFU.Signaling.LiveKit` (protobuf over
   WebSocket) both drive the same `Room` and `Participant.WebRTC` API. The
   LiveKit protocol models the core: rooms, participants, track SIDs,
   `TrackInfo`, `ParticipantInfo`, mute and subscription updates. The JSON
   protocol is a small JSON form of the same model.
3. **One peer connection for each client.** The current LiveKit JS client
   (`client-sdk-js` main) uses `singlePeerConnection: true` by default. It
   connects to `/rtc/v1` with a `join_request` query parameter (a base64url
   `WrappedJoinRequest`, raw or GZIP). It uses the dual peer connection path
   `/rtc` (publisher and subscriber) only when `/rtc/v1` returns 404. We
   implement `/rtc/v1` with one peer connection first. `/rtc` (dual peer
   connections) is a later step, and only if an SDK we test needs it.
4. **Data channels in-band.** LiveKit server protocol 18 and later creates
   negotiated data channels (fixed SCTP stream IDs). `ex_webrtc` 0.18 does
   not support `negotiated: true`. Our server reports protocol 17, so
   clients open data channels in-band. Contributing negotiated data channels
   to `ex_webrtc` is a follow-up.
5. **Tokens.** One token format for both protocols: LiveKit-compatible
   HS256 JWTs (`iss` = API key, `sub` = identity, `video` grant with `room`,
   `roomJoin`, `canPublish`, `canSubscribe`, `canPublishData`). Use Joken
   (Hex 2.8.0, updated 2026-11-13). LiveKit server SDKs can then make tokens
   for our SFU.
6. **Audio first, forward without transcoding.** The SFU forwards RTP as it
   arrives (Opus from clients, PCMU from telephony). The agent decodes and
   encodes. Video, simulcast and SVC come later.
7. **Agents join over Erlang distribution, not WebRTC.** An agent is a
   *native participant*. It sends and receives `ExRTP.Packet` terms as
   messages, with no ICE, DTLS or SRTP. The contract is plain tuples with a
   protocol version, called through `:erpc`, so AudioFlow does not need the
   SFU code at compile time. Sends use `:erlang.send/3` with `[:nosuspend]`,
   and packets are dropped when the distribution buffer is busy. Old audio
   has no value. To clients, an agent looks like a normal LiveKit
   participant with `ParticipantInfo.kind = AGENT`.
8. **The SFU keeps a participant "away" when its node goes down.** On
   `nodedown` or `DOWN`, a native participant stays in the room for
   `:away_timeout_ms` (default 30 000). Clients see no leave. A rejoin with
   the same identity and resume token gets the same participant SID, track
   SIDs and subscriptions.
9. **Room state is soft state.** A participant process owns its peer
   connection, tracks and subscriptions. It is not a child of the `Room`
   process. If a `Room` crashes, its supervisor restarts it. The participants
   see `DOWN`, find the new room through `Registry`, and register again. A
   `Room` crash drops no media path. A crash of a participant process closes
   its peer connection, and that client must reconnect (ICE restart or
   LiveKit resume with `reconnect=1`).
10. **The call, not the session, is durable.** `AudioFlow.Session` stays an
    in-memory, `restart: :temporary` GenServer. A new `AudioFlow.Calls.Call`
    process owns the SFU participant and the session. After each committed
    turn, it writes a snapshot to an `AudioFlow.CallStore`. Adapter options
    contain functions and PIDs, so the store saves a reference to an
    `AudioFlow.Agent` module. That module rebuilds the session options from
    the stored call metadata (similar to the LiveKit agent `entrypoint`).
11. **Leases with fencing.** Each active call has a Postgres lease
    (`lease_owner`, `lease_expires_at`, `version`), default `lease_ms`
    10 000. The owner renews it every `lease_ms / 3`. Other nodes claim
    expired leases with `FOR UPDATE SKIP LOCKED`. Every write checks
    `version`, so a stale owner cannot overwrite a newer snapshot.
12. **Drain on deploy.** `AudioFlow.Application.prep_stop/1` stops new claims,
    lets active turns finish (bounded by `:drain_timeout_ms`), writes a
    snapshot and releases each lease at once. Another node claims the call
    in less than one renewal interval.
13. **Interrupted turns.** A turn that is running when a node stops is lost.
    The default policy `:drop` keeps the history from the last committed
    turn, plus the reply chunks that playback acknowledged (current
    `Playout` behavior). Optional `:retry_input` submits the stored user
    input again as `AudioFlow.Text` if it is newer than `:retry_window_ms`.
    Use it only with idempotent tools.
14. **Hot upgrades in all releases.** Each stateful GenServer gets `@vsn`
    and an explicit `code_change/3`. AudioFlow and the SFU each ship an
    `appup.exs` through the Forecastle appup compiler. `releases/` uses
    `Castle.customize/1`. Upgrades that change `ex_webrtc` or other native
    dependencies use a restart plus drain, not a hot upgrade.

### New and changed modules

AudioFlow (root project):

- `lib/audio_flow/rtp/reorder.ex`: `AudioFlow.RTP.Reorder`, taken out of
  `AudioFlow.WebRTC.Session`. It is in the core because it needs no
  `ex_webrtc` code, and `lib_sfu` uses it too.
- `lib_sfu/audio_flow/sfu/participant.ex`: `AudioFlow.SFU.Participant`. It
  joins a room as a native participant, reorders RTP, decodes Opus or PCMU,
  resamples to 16 kHz (`AudioFlow.Resampler`), and feeds `AudioFlow.VoiceInput`
  and the session. Its structure follows `AudioFlow.WebRTC.Session`.
- `lib_sfu/audio_flow/sfu/transport.ex`: `AudioFlow.SFU.Transport`. It
  implements `AudioFlow.Output` and `AudioFlow.PausableOutput` and sends
  paced 20 ms Opus RTP packets. Pacing follows `AudioFlow.WebRTC.Transport`.
  Opus uses `Membrane.Opus.Encoder.Native` and `Membrane.Opus.Decoder.Native`,
  as `AudioFlow.Moshi.Codec` does.
- `lib/audio_flow/agent.ex`: `AudioFlow.Agent` behaviour with
  `session_options(call)` and optional `participant_options(call)`.
- `lib/audio_flow/call_store.ex` with `call_store/memory.ex` (ETS) and
  `call_store/postgres.ex` (Postgrex, already a dependency).
- `lib/audio_flow/calls.ex`, `lib/audio_flow/calls/call.ex`,
  `lib/audio_flow/calls/claimer.ex`. They start from `AudioFlow.Application`
  only when `:audio_flow, :calls` is configured.
- `lib/audio_flow/session.ex`: new options `:restore`
  (`%{history: turns, conversation_state: atom, turns: n}`) and `:on_commit`
  (a one-argument function that gets a snapshot after each committed turn).
- `lib/audio_flow/history.ex`: `History.restore/2` and `History.snapshot/1`.
- `lib/audio_flow/application.ex`: optional `AudioFlow.Calls` child and
  `prep_stop/1` drain.
- `appup.exs`, and `@vsn` / `code_change/3` in `Session`, `Worker`, `Duplex`,
  `WebRTC`, `WebRTC.Session`, `WebRTC.Transport`, `SFU.Participant`,
  `SFU.Transport` and `Calls.Call`.
- `mix.exs`: a new `AUDIOFLOW_SFU=1` flag. It adds `lib_sfu` and
  `membrane_opus_plugin` and a `_sfu` build profile suffix.

SFU (`sfu/`, app `:audio_flow_sfu`):

- `AudioFlowSFU.Application`, `AudioFlowSFU.Rooms` (DynamicSupervisor and
  Registry), `AudioFlowSFU.Room`.
- `AudioFlowSFU.Participant.WebRTC` (one peer connection for each client,
  publish and subscribe, server-side renegotiation, ICE restart through
  `PeerConnection.create_offer(pc, ice_restart: true)`, in-band data
  channels).
- `AudioFlowSFU.Participant.Native` (agent participants over distribution).
- `AudioFlowSFU.Participant.Telephony` (Twilio and Telnyx Media Streams as a
  PCMU track).
- `AudioFlowSFU.Signaling.JSON` (WebSock: `join`, `offer`, `answer`,
  `candidate`, `resume`, `leave`, room events).
- `AudioFlowSFU.Signaling.LiveKit` (WebSock at `/rtc/v1`, `SignalRequest` and
  `SignalResponse` protobuf, `JoinResponse`, `ReconnectResponse`,
  `TrackPublishedResponse`, `ParticipantUpdate`, `TrickleRequest`, ping and
  pong) and the HTTP `/rtc/v1/validate` endpoint that the client calls on a
  connection error.
- `AudioFlowSFU.LiveKit.Proto`: modules generated with `protobuf` (Hex
  0.17.1) from a pinned commit of `livekit/protocol`
  (`protobufs/livekit_rtc.proto`, `livekit_models.proto` and imports),
  committed to the repository with a regeneration script.
- `AudioFlowSFU.Token` (Joken, LiveKit claims).
- `AudioFlowSFU.Telemetry` (room, participant and track events,
  `PeerConnection.get_stats/1` samples).
- `sfu/appup.exs`.

Releases (`releases/`, app `:audio_flow_releases`): `mix.exs` with Castle and
the two releases, `appup.exs`, and `scripts/upgrade_test.sh`.

### Out of scope (later plans)

- LiveKit `/rtc` dual peer connection path, unless a tested SDK needs it.
- LiveKit server APIs: Twirp `RoomService`, Egress, Ingress, SIP service,
  the agent worker protocol, data tracks and the data blob store.
- Video, simulcast, SVC and congestion control.
- Room cascading across SFU nodes. In this plan one room lives on one SFU node.
- A built-in TURN server. Use an external TURN server through `:ice_servers`.
- End-to-end encryption.

## Implementation Phases

### Phase 1: Shared RTP reorder buffer

- Move the RTP reorder logic from `AudioFlow.WebRTC.Session` into
  `AudioFlow.RTP.Reorder` (a pure data structure with `push/2`, `waiting?/1`
  and `skip/1`).
- Use it in `AudioFlow.WebRTC.Session`. `AudioFlow.Telephony.WebSocket`
  keeps its own buffer: it orders non-wrapping Telnyx chunk numbers with a
  byte limit, not 16-bit RTP sequence numbers.
- Keep the error atoms (`:rtp_reorder_limit`, `:rtp_gap_timeout`) the same.

**Commit:** `refactor(webrtc): share the RTP reorder buffer`

### Phase 2: Hot-upgrade-safe AudioFlow processes

- Add `@vsn 1` and an explicit `code_change/3` to `AudioFlow.Session`,
  `AudioFlow.Worker`, `AudioFlow.Duplex`, `AudioFlow.WebRTC`,
  `AudioFlow.WebRTC.Session` and `AudioFlow.WebRTC.Transport`.
- Add `{:castle, "~> 1.3", runtime: false}` (it brings Forecastle, as the
  Forecastle README asks), `appup: "appup.exs"` and the `:appup` compiler to
  `mix.exs`. Add `appup.exs` for 0.1.0. Forecastle installs dependency appups
  from `ebin` into the release, so the library can ship its own appup.
- Add `test/hot_upgrade_test.exs`. It suspends a live session in the middle
  of a turn (`:sys.suspend/1`), loads a changed module, calls
  `:sys.change_code/4` and `:sys.resume/1`, and checks that the turn
  completes and the history is the same.
- Add `site/src/content/docs/docs/guides/hot-upgrades.md`.

**Commit:** `feat(upgrade): make session processes hot-upgradable`

### Phase 3: SFU audio rooms with JSON signaling

- Create `sfu/` (`mix.exs`, `.formatter.exs`, `README.md`) with
  `ex_webrtc ~> 0.18.0`, `ex_sctp` (data channels, a Rust NIF), `bandit`,
  `websock_adapter` and `joken`. Each offer has a `_reliable` data channel,
  so a client with no tracks yet still has a media section and connects.
- Add `Room`, `Participant.WebRTC`, `Signaling.JSON` and `Token`.
  Negotiate Opus and PCMU only.
- Forward each published audio track to each subscriber with
  `PeerConnection.send_rtp/4`. Subscribe to all audio tracks by default.
- Tests in `sfu/test/`: two `ExWebRTC.PeerConnection` test clients join a
  room, publish and receive Opus RTP. Bad and expired tokens are rejected.
  `:max_participants` is enforced.
- Add a CI job for `sfu/` in `.github/workflows/tests.yml`. Exclude `sfu/**`
  and `releases/**` from the root `mix-format` step in `hk.pkl`, as for
  `ui/**`.

**Commit:** `feat(sfu): add audio rooms with JSON signaling`

### Phase 4: SFU resilience

- Participants register again after a `Room` crash.
- Resume token and `:away_timeout_ms` (default 30 000) on client reconnect.
- The server sends an ICE restart offer when the client asks or when ICE
  goes to `disconnected`.
- Telemetry: `[:audio_flow_sfu, :room, :start | :stop]`,
  `[:audio_flow_sfu, :participant, :join | :away | :resume | :leave]`,
  `[:audio_flow_sfu, :track, :publish | :unpublish]`.
- Tests: kill the `Room` process while two clients exchange RTP, and check
  that RTP continues on the same peer connection. Drop a client socket and
  resume within the timeout. A resume after the timeout fails.

**Commit:** `feat(sfu): keep calls through room crashes and client reconnects`

### Phase 5: LiveKit client protocol

- Add `sfu/scripts/gen_livekit_proto.sh` and the generated
  `AudioFlowSFU.LiveKit.Proto` modules from a pinned `livekit/protocol`
  commit.
- Add `Signaling.LiveKit` on `/rtc/v1`: decode `join_request`
  (`WrappedJoinRequest`, NONE or GZIP), validate the JWT, answer the
  publisher offer, send `JoinResponse` with `ServerInfo.protocol = 17`, ICE
  servers and other participants.
- Map `AddTrackRequest` → `TrackPublishedResponse`, `MuteTrackRequest`,
  `UpdateSubscription`, `TrickleRequest`, `LeaveRequest`, `Ping` → `Pong`.
  Send `ParticipantUpdate`, `TrackSubscribed` and `SpeakersChanged` (from
  RTP audio levels if present, else from Opus packet sizes).
- Map LiveKit resume (`reconnect=1`, `ReconnectResponse`) onto the Phase 4
  resume. Map native agent participants to `ParticipantInfo.kind = AGENT`.
- Add `/rtc/v1/validate` (200, 401, 404 with the texts the client checks).
- Compatibility tests:
  - `sfu/test/livekit_signaling_test.exs`: protobuf round trips and a join
    with an `ExWebRTC.PeerConnection` test client.
  - `sfu/compat/js/`: a headless browser test with `livekit-client` (pinned
    version) that joins, publishes a microphone fixture (Chromium
    `--use-file-for-fake-audio-capture`), and receives the echo track of a
    test participant.
  - `sfu/compat/python/`: the same test with the Python `livekit` rtc SDK
    (pinned version), run with `uv`. If this SDK needs `/rtc` dual peer
    connections, record that and add the `/rtc` path to the plan.

**Commit:** `feat(sfu): accept LiveKit client SDKs`

### Phase 6: Native agent participants in the SFU

- Add `AudioFlowSFU.join_native(room, identity, pid, opts)`. It returns
  `{:ok, %{participant: ref, resume_token: binary, tracks: [...]}}` and starts
  `Participant.Native`, which monitors the agent PID.
- Native publish: `AudioFlowSFU.publish(participant, track_id, packet)` (cast).
  Native subscribe: the participant sends
  `{:audio_flow_sfu, 1, participant, {:rtp, track_id, packet}}` to the agent
  PID with `[:nosuspend]` and counts drops in telemetry.
- When the agent goes down, the participant becomes `away`. Other members get
  an away event (JSON) or a `ParticipantUpdate` with unchanged state
  (LiveKit, so that SDKs do not show a leave). Its track stays published and
  sends no RTP. A `join_native` with the same identity and resume token
  takes the participant back.
- Distributed tests with `:peer`, as in `test/distributed_worker_test.exs`.

**Commit:** `feat(sfu): add BEAM-native agent participants`

### Phase 7: Release project and hot-upgradable SFU

- Add `@vsn` and `code_change/3` to `Room`, `Participant.WebRTC`,
  `Participant.Native` and both signaling modules. Add `sfu/appup.exs`.
- Create `releases/` with path dependencies on `..` and `../sfu`, Castle,
  and the `audio_flow_sfu` and `audio_flow_dev` releases
  (`Castle.customize/1`, `upgrade_from:` set from a CI variable).
- Add `releases/scripts/upgrade_test.sh`. It builds `audio_flow_sfu` from the
  previous git ref (`ref:` baseline), starts it, connects a test client,
  builds the current release with a relup, installs it with Castle, and
  checks that the same peer connection keeps receiving RTP with no gap over
  100 ms.
- Run the script in CI on pull requests that change `sfu/` or `releases/`.

**Commit:** `feat(releases): ship hot-upgradable SFU and dev releases`

### Phase 8: AudioFlow sessions as room participants

- Add the `AUDIOFLOW_SFU=1` flag and `lib_sfu` to `mix.exs`, with a `_sfu`
  build profile suffix and `membrane_opus_plugin`.
- Add `AudioFlow.SFU.Participant` and `AudioFlow.SFU.Transport`. Opus packet
  loss uses decoder packet loss concealment if
  `Membrane.Opus.Decoder.Native` supports it. If not, insert silence for each
  lost 20 ms frame. The call does not end, unlike `AudioFlow.WebRTC.Session`.
- Speech start cancels output (as in `WebRTC.Session.handle_voice_event/2`).
- Tests: an SFU on a `:peer` node, a WebRTC test client that publishes an
  Opus fixture, and an AudioFlow session with the demo adapters that answers
  through the room. Repeat with the `livekit-client` compatibility test.

**Commit:** `feat(sfu): run AudioFlow sessions as room participants`

### Phase 9: Durable call state

- Add `AudioFlow.Agent`, `AudioFlow.CallStore`, `CallStore.Memory` and
  `CallStore.Postgres`. Add `CallStore.Postgres.schema_sql/0` and document
  the `audio_flow_calls` table: `id uuid`, `room text`, `agent text`,
  `metadata jsonb`, `history jsonb`, `conversation_state text`, `turns int`,
  `pending_input jsonb`, `resume_token bytea`, `status text`,
  `lease_owner text`, `lease_expires_at timestamptz`, `version bigint`,
  `updated_at timestamptz`.
- Add `:restore` and `:on_commit` to `AudioFlow.Session`, and
  `History.restore/2` and `History.snapshot/1`. `:on_commit` runs after the
  history and conversation transition are committed. Its failure is an
  event and does not fail the turn.
- Add `AudioFlow.Calls.Call`. It starts the session from
  `agent.session_options(call)`, joins the room, and writes snapshots with a
  `version` check.
- Tests: Memory and Postgres store contract tests (Postgres with a
  `TEMP TABLE`, as in `test/rag_pgvector_test.exs`). A restored session gives
  the same LLM prompt as the original session.

**Commit:** `feat(calls): persist call state after each turn`

### Phase 10: Rejoin, leases and drain

- Add `AudioFlow.Calls.Claimer` (`lease_ms` default 10 000). It renews local
  leases and claims expired ones. A claimed call restarts its `Call` process
  with `:restore` and rejoins with the stored resume token.
- Add `:interrupted_turn` (`:drop` default, `:retry_input`),
  `:retry_window_ms`, and an optional `:resume_prompt` text.
- Add `prep_stop/1` drain in `AudioFlow.Application` with `:drain_timeout_ms`.
- Tests: kill an agent `:peer` node in the middle of a call. A second node
  claims it within `lease_ms + 2 s`, the client peer connection stays the
  same, and the next turn uses the stored history. A drained stop hands over
  in less than one renewal interval. A stale owner write fails on `version`.

**Commit:** `feat(calls): rejoin calls after node restarts and drain on deploy`

### Phase 11: Telephony participants in rooms

- Add `AudioFlowSFU.Participant.Telephony`. It ends Twilio and Telnyx Media
  Streams WebSockets in the SFU and publishes PCMU as a track. Copy the
  framing and μ-law rules from `AudioFlow.Telephony.WebSocket` and
  `AudioFlow.Telephony.MuLaw`, because the SFU does not depend on AudioFlow.
- `AudioFlow.SFU.Participant` accepts PCMU tracks with
  `AudioFlow.Telephony.MuLaw` and `AudioFlow.Telephony.RateConverter`.
- Tests: a phone call stays connected while the agent node restarts.

**Commit:** `feat(sfu): bridge telephony media streams into rooms`

### Phase 12: Example and documentation

- Add `examples/durable-call/` with a `livekit-client` browser page, the
  `audio_flow_dev` release, and a script that kills and restarts the agent
  node during the call.
- Add `site/src/content/docs/docs/features/durable-calls.md` and
  `site/src/content/docs/docs/features/sfu.md` (both protocols, tokens,
  LiveKit SDK compatibility table). Update `transports.md` and the README.
- Update `docs/research/competitive-landscape.md` with durable calls, the
  BEAM SFU, LiveKit SDK compatibility and hot upgrades.

**Commit:** `docs(calls): document durable calls and the SFU`

## Risks & Tradeoffs

- **LiveKit protocol drift.** The protocol changes often (`client-sdk-js`
  now defaults to protocol 18 and one peer connection). Pin the proto commit
  and the SDK versions in the compatibility tests. Update them on purpose.
- **Data channel gap.** Reporting protocol 17 works only while clients still
  support in-band data channels. Mitigation: upstream negotiated data
  channels to `ex_webrtc`.
- **Dual peer connection SDKs.** Some LiveKit SDKs may still use `/rtc`
  only. The Phase 5 Python test shows this early.
- **SFU crash still drops media.** Only `Room` crashes are free. A crash of
  a participant process or of the SFU node closes peer connections, and
  clients must resume.
- **ex_webrtc capacity.** Each peer connection is a set of BEAM processes
  with DTLS and SRTP. Add an SFU benchmark (rooms × participants, CPU, RTP
  jitter) before we claim capacity numbers.
- **Erlang distribution trust.** Agent and SFU nodes must be in one trusted
  cluster. Use TLS distribution across hosts.
- **Distribution backpressure.** `[:nosuspend]` drops packets instead of
  blocking. Report drops in telemetry.
- **Hot upgrades are not free.** Each state change needs a correct
  `code_change/3` and appup. Native dependency upgrades need a restart. The
  CI upgrade test is the gate.
- **Lease gap.** After a crash, the agent is silent for up to `lease_ms`
  (10 s). A drain has no such gap.
- **`:retry_input` can repeat tool side effects.** It is off by default.
- **More to deploy.** Users run an SFU release and their agent release.
  `audio_flow_dev` runs both on one node for development and is not durable.

## Open Questions

- Does `Membrane.Opus.Decoder.Native` expose packet loss concealment or FEC?
- Which `livekit/protocol` commit and SDK versions do we pin first?
