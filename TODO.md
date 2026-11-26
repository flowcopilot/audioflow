# TODO: Durable voice agent calls (AudioFlow SFU, hot upgrades, call rejoin)

## Phase 1: Shared RTP reorder buffer

- [x] Add `AudioFlow.RTP.Reorder` with code taken from `AudioFlow.WebRTC.Session`
- [x] Use it in `AudioFlow.WebRTC.Session`
- [x] Compare with `AudioFlow.Telephony.WebSocket` reorder code (kept: it orders Telnyx chunk numbers, not RTP)
- [x] `test/webrtc_session_test.exs` and `test/telephony_reorder_test.exs` pass (state paths updated)
- [x] Commit: `refactor(webrtc): share the RTP reorder buffer`

## Phase 2: Hot-upgrade-safe AudioFlow processes

- [x] `@vsn 1` and `code_change/3` in `Session`, `Worker`, `Duplex`, `WebRTC`, `WebRTC.Session`, `WebRTC.Transport`
- [x] Forecastle appup compiler and `appup.exs` in the root `mix.exs` (through `{:castle, runtime: false}`)
- [x] `test/hot_upgrade_test.exs`: change code of a live session in the middle of a turn
- [x] `site/src/content/docs/docs/guides/hot-upgrades.md`
- [x] Commit: `feat(upgrade): make session processes hot-upgradable`

## Phase 3: SFU audio rooms with JSON signaling

- [x] Create the `sfu/` Mix project (`:audio_flow_sfu`) with `ex_webrtc`, `ex_sctp`, `bandit`, `websock_adapter`, `joken`
- [x] `AudioFlowSFU.Room`, `Participant.WebRTC`, `Signaling.JSON`, `Token` (LiveKit JWT claims)
- [x] Opus and PCMU audio forwarding with `PeerConnection.send_rtp/4`
- [x] Tests: two test peers exchange Opus RTP; bad and expired tokens rejected; `:max_participants` enforced
- [x] CI job for `sfu/`; `sfu/**` and `releases/**` excluded from root `mix-format` in `hk.pkl`
- [x] Commit: `feat(sfu): add audio rooms with JSON signaling`

## Phase 4: SFU resilience

- [x] Participants register again after a `Room` crash (`Room.rejoin/3` and a `{:sync, members}` broadcast)
- [x] Resume token and `:away_timeout_ms` (30 000) on client reconnect; a dropped socket no longer leaves
- [x] ICE restart offer with `create_offer(pc, ice_restart: true)` (on `failed`, or the `ice_restart` message)
- [x] Telemetry events for room, participant, track lifecycle and dropped RTP
- [x] Tests: `Room` kill keeps RTP flowing on the same peer connection; resume within and after the timeout
- [x] Commit: `feat(sfu): keep calls through room crashes and client reconnects`

## Phase 5: LiveKit client protocol

- [x] Pin a `livekit/protocol` commit (v1.54.2); add `sfu/scripts/gen_livekit_proto.sh` and generated modules
- [x] `Signaling.LiveKit` on `/rtc/v1`: `join_request` (NONE and GZIP, bounded inflate), JWT (query or bearer header), publisher offer, `JoinResponse` with protocol 17
- [x] Map `AddTrackRequest`, `MuteTrackRequest`, `TrickleRequest`, `LeaveRequest`, `Ping` (`UpdateSubscription` is ignored: auto subscribe only)
- [x] Send `ParticipantUpdate` and `MediaSectionsRequirement` (`TrackSubscribed` and `SpeakersChanged` are not sent yet)
- [x] LiveKit resume (`reconnect` with `participant_sid`, `ReconnectResponse`) on top of the Phase 4 resume
- [x] `/rtc/v1/validate` with 200 and 401 responses
- [x] `sfu/test/livekit_signaling_test.exs`
- [x] `sfu/compat/js/`: headless `livekit-client` 2.24.0 join, publish, receive, signal resume, leave
- [x] `sfu/compat/python/`: Python `livekit` 1.2.1 join, publish and receive; it uses `/rtc/v1`, so `/rtc` is not needed
- [x] Commit: `feat(sfu): accept LiveKit client SDKs`

## Phase 6: Native agent participants in the SFU

- [x] `AudioFlowSFU.Native.join/4` and `publish_track/3` (callable with `:erpc`); agents send `{:audio_flow_sfu, 1, {:rtp, track_sid, rtp}}`
- [x] Versioned plain-term RTP and event messages to the agent with `[:nosuspend]` and drop telemetry
- [x] `away` state on agent `DOWN`/`nodedown`; no leave shown to JSON or LiveKit clients; rejoin with the resume token
- [x] Agents shown as `ParticipantInfo.kind = AGENT` to LiveKit clients
- [x] Distributed `:peer` tests for join, publish, subscribe, away and rejoin (`test_helper.exs` starts distribution)
- [x] Commit: `feat(sfu): add BEAM-native agent participants`

## Phase 7: Release project and hot-upgradable SFU

- [x] `@vsn` and `code_change/3` in `Room`, `Participant.WebRTC`, `Participant.Native` (the signaling modules are WebSock handlers with no `code_change/3`)
- [x] `sfu/appup.exs` and the Forecastle appup compiler in `sfu/mix.exs`
- [x] `releases/` project with Castle, `audio_flow_sfu` and `audio_flow_dev` releases
- [x] `releases/scripts/upgrade_test.sh`: upgrade 0.1.0 to 0.1.1 during a live call, no reconnect, no audio gap over 100 ms (local run: 35 ms)
- [x] CI runs the upgrade test on changes to `sfu/` or `releases/` (`.github/workflows/sfu-upgrade.yml`)
- [x] Commit: `feat(releases): ship hot-upgradable SFU and dev releases`

## Phase 8: AudioFlow sessions as room participants

- [x] Check whether `Membrane.Opus.Decoder.Native` has packet loss concealment (it does not: `decode_packet/2` needs a packet)
- [x] `AUDIOFLOW_SFU=1` flag, `lib_sfu`, `_sfu` build profile, `membrane_opus_plugin`
- [x] `AudioFlow.SFU.Participant` (reorder, Opus or PCMU decode, resample, VoiceInput, session)
- [x] `AudioFlow.SFU.Transport` (`AudioFlow.Output`, paced 20 ms Opus RTP maps; no `PausableOutput`, as for `WebRTC.Transport`)
- [x] Lost packets become 20 ms of silence after the gap timeout; the call does not end
- [x] Tests: stub-SFU unit tests (`test/sfu_participant_test.exs`) and a real call in `releases/test/agent_call_test.exs` (the livekit-client run with an agent is in the Phase 12 example)
- [x] Commit: `feat(sfu): run AudioFlow sessions as room participants`

## Phase 9: Durable call state

- [x] `AudioFlow.Agent` behaviour
- [x] `AudioFlow.CallStore` behaviour, `CallStore.Memory`, `CallStore.Postgres`, `schema_sql/1`
- [x] `AudioFlow.Session` `:restore` and `:on_commit`; `History.restore/2`, `History.snapshot/1`
- [x] `AudioFlow.Calls.Call` (in `lib_sfu`) with `version`-checked snapshot writes and the saved resume token
- [x] Tests: store contract for both stores (Postgres with `AUDIOFLOW_POSTGRES_URL`, concurrent claims); restored session gives the same LLM prompt; restored conversation state
- [x] Commit: `feat(calls): persist call state after each turn`

## Phase 10: Rejoin, leases and drain

- [ ] `AudioFlow.Calls.Claimer` (`lease_ms` 10 000, renew, claim with `FOR UPDATE SKIP LOCKED`)
- [ ] `:interrupted_turn` (`:drop`, `:retry_input`), `:retry_window_ms`, `:resume_prompt`
- [ ] `AudioFlow.Application.prep_stop/1` drain with `:drain_timeout_ms`
- [ ] Tests: agent node kill and claim within `lease_ms + 2 s`; drain handover; stale `version` write fails
- [ ] Commit: `feat(calls): rejoin calls after node restarts and drain on deploy`

## Phase 11: Telephony participants in rooms

- [ ] `AudioFlowSFU.Participant.Telephony` for Twilio and Telnyx Media Streams
- [ ] `AudioFlow.SFU.Participant` accepts PCMU tracks
- [ ] Test: phone call stays connected during an agent node restart
- [ ] Commit: `feat(sfu): bridge telephony media streams into rooms`

## Phase 12: Example and documentation

- [ ] `examples/durable-call/` with a `livekit-client` page, `audio_flow_dev`, and a kill-and-restart script
- [ ] `site/src/content/docs/docs/features/durable-calls.md` and `sfu.md`; update `transports.md` and `README.md`
- [ ] Update `docs/research/competitive-landscape.md`
- [ ] Commit: `docs(calls): document durable calls and the SFU`

## Verification

- [ ] `mix test` passes for the core, `AUDIOFLOW_WEBRTC=1`, and `AUDIOFLOW_WEBRTC=1 AUDIOFLOW_SFU=1` profiles
- [ ] `mix test` passes in `sfu/`, `releases/`, `ui/` and `examples/chat`
- [ ] Distributed tests pass with `elixir --sname audioflow_test -S mix test --only distributed`
- [ ] Postgres tests pass with a real Postgres (`CallStore.Postgres`, lease claim, fencing)
- [ ] LiveKit compatibility tests pass for the pinned `livekit-client` and Python `livekit` versions
- [ ] Manual smoke test: a `livekit-client` browser page joins a room, talks to the agent, `kill -9` on the agent node, a second node rejoins, the browser stays connected, and the agent remembers the earlier turns
- [ ] Manual smoke test: SIGTERM on the agent node during a call hands over in less than one renewal interval
- [ ] Manual smoke test: hot upgrade of `audio_flow_sfu` during a call with no audible gap
- [ ] Edge cases: agent crash in the middle of a turn (`:drop` and `:retry_input`); rejoin after `:away_timeout_ms`; two nodes claim the same lease at once; `Room` crash during renegotiation; client ICE restart during agent speech; distribution buffer full; GZIP `join_request`; expired JWT on LiveKit resume
- [ ] Data integrity: a stale lease owner cannot overwrite a newer snapshot; `schema_sql/0` applies to an empty database and is documented with its rollback (`DROP TABLE audio_flow_calls`)
- [ ] No regressions in `AudioFlow.WebRTC.Session`, `AudioFlow.Telephony.WebSocket`, interruption and `Playout` history truncation
- [ ] `mix audio_flow.bench` hot paths show no regression

## Review

- [ ] Code reviewed
- [ ] PLAN.md updated if approach changed during implementation
- [ ] All phase commits are clean and describe their intent
- [ ] TODO.md items all checked off
