---
title: Durable calls
description: Calls that stay connected when an agent node is deployed, restarted or lost, with saved history and lease handover.
---

A durable call stays connected when the node that runs its agent stops. The
user does not notice a deploy, and after a crash the agent comes back with the
same history within one lease.

Three parts make this work:

1. **The media ends in the SFU, not on the agent node.** Users connect to the
   [AudioFlow SFU](../sfu/). The agent joins the same room as a native
   participant over Erlang distribution. An agent node that stops does not
   close the user's peer connection.
2. **The call state is in a store.** After each committed turn, the call saves
   its history, conversation state and turn count to an `AudioFlow.CallStore`
   (PostgreSQL, or memory for tests).
3. **Nodes hold calls with leases.** Every agent node renews the leases of its
   calls and claims calls whose leases expired. A claimed call starts its
   session from the saved state and takes back its SFU participant with the
   saved resume token, so the room sees the same agent and the same track.

## Set up an agent

An agent module builds the session for a call. The store saves the module
name, not the options, because options hold functions and PIDs.

```elixir
defmodule MyApp.SupportAgent do
  @behaviour AudioFlow.Agent

  @impl true
  def session_options(call) do
    [history: true, stt: ..., llm: ..., tts: ...]
  end

  @impl true
  def participant_options(_call) do
    [vad: {AudioFlow.Silero, []}, voice_input: [min_silence_ms: 500]]
  end
end
```

Build AudioFlow with `AUDIOFLOW_SFU=1` and configure the calls on every agent
node:

```elixir
config :audio_flow, :calls,
  store: {AudioFlow.CallStore.Postgres, connection: MyApp.DB},
  sfu: :"sfu@10.0.0.5",
  lease_ms: 10_000
```

Create the table once with `AudioFlow.CallStore.Postgres.schema_sql/1`. Start
a call when a user joins a room, for example from your token endpoint:

```elixir
{:ok, call} = AudioFlow.Calls.start_call(room, MyApp.SupportAgent, %{"customer" => id})
```

## What happens when a node stops

| Event | Result |
| --- | --- |
| Deploy (SIGTERM) | `prep_stop` drains: running turns finish (up to `:drain_timeout_ms`), the agent participant waits as away, and the lease ends at once. Another node claims the call at its next renewal, in about `lease_ms / 3`. |
| Crash or `kill -9` | The SFU keeps the agent participant away for 30 s. Another node claims the call when the lease expires, after at most `lease_ms`. |
| Network split | The old owner cannot renew its lease. Its next save fails on the version check, and it stops. |
| Hot upgrade | No handover. See [hot upgrades](../../guides/hot-upgrades/). |

A turn that runs when a node crashes is lost. By default the history keeps
the turns before it. With `interrupted_turn: :retry_input`, the new node
submits the interrupted user input again as text, if it is newer than
`:retry_window_ms`. Use this only with idempotent tools. `:resume_input` is
optional text that the session gets as user input after a move, for example
an instruction to say that the agent is back.

A call ends when the last user leaves the room, or when no user has been in
the room for `:empty_timeout_ms` (60 s).

## Check it

`examples/durable-call/run.sh` starts an SFU node and an agent node with a
call. With `SMOKE=1`, a headless Chromium with `livekit-client` talks to the
agent, the script kills the agent node with `kill -9`, starts a second agent
node, and checks that the agent answers again and that the user connection
never dropped. In a local run, the second node answered 5.5 s after the kill
with a 5 s lease.

`releases/test/durable_call_test.exs` runs the same cases with agent nodes
on `:peer`: a crash with the history kept, a drain that hands over faster
than the lease, and a retried interrupted input.
