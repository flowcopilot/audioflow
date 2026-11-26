# AudioFlow releases

This project builds the releases with [Castle](https://hexdocs.pm/castle), so
each release can be upgraded in place while calls continue.

| Release | Contents | Use |
| --- | --- | --- |
| `audio_flow_sfu` | `:audio_flow_sfu` | Production SFU nodes |
| `audio_flow_dev` | `:audio_flow_sfu` and `:audio_flow` on one node | Development only. Build with `AUDIOFLOW_DEV_RELEASE=1`. An agent restart here also stops the SFU, so calls are not durable. |

```sh
MIX_ENV=prod mix release audio_flow_sfu
```

Set `CASTLE_UPGRADE_FROM` to the baselines the new version upgrades from
(comma-separated, for example `tar:artifacts/audio_flow_sfu-0.1.0.tar.gz`) to
add a relup. Then install it on a running node:

```sh
bin/castle unpack 0.1.1
bin/castle install 0.1.1
bin/castle commit
```

The SFU reads `AUDIOFLOW_SFU_PORT`, `AUDIOFLOW_SFU_API_KEY`,
`AUDIOFLOW_SFU_API_SECRET` and `AUDIOFLOW_SFU_ICE_SERVERS` at start.

`scripts/upgrade_test.sh` builds 0.1.0 and a 0.1.1 that migrates the room
state, holds a LiveKit Python SDK call, installs 0.1.1 during the call, and
fails on a reconnect or an audio gap over 100 ms.
