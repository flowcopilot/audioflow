# Durable call example

A call that stays connected when the agent node dies. A browser user talks to
an agent through the AudioFlow SFU. You stop the agent node with `kill -9`;
a second agent node takes the call over with its history, and the browser
stays connected.

The agent answers each utterance with a tone, so no models are needed.

## Run

You need PostgreSQL, Node.js and the tool versions in `mise.toml`.

```sh
cd examples/durable-call
npm ci
AUDIOFLOW_POSTGRES_URL=postgres://user:pass@localhost:5432/db ./run.sh
```

`run.sh` starts the SFU node (`sfu@127.0.0.1`, port 7880) and agent node A,
creates a call in a new room, and prints:

1. The page URL with a token. Open it, select **Start**, and allow the
   microphone. Make a sound: the agent answers with a tone.
2. The `kill -9` command for node A. Run it during the call.
3. The command that starts node B. Run it. Node B claims the call when the
   lease (5 s) expires, and the agent answers again.

The browser connection does not drop. The page uses `livekit-client`.

## Automated check

```sh
npx playwright install chromium-headless-shell
SMOKE=1 AUDIOFLOW_POSTGRES_URL=... ./run.sh
```

A headless Chromium with a fake microphone runs the same steps and fails if
the user connection drops or the agent does not answer again.
