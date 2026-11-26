---
title: Hot upgrades
description: Upgrade a running AudioFlow node without dropping calls, with Castle relups and AudioFlow's appup.
sidebar:
  order: 13
---

A hot upgrade loads new code into a running node. Live sessions, workers and
WebRTC peers keep their processes and state, so calls continue. AudioFlow
supports hot upgrades through [Castle](https://hexdocs.pm/castle) and its
build-time part, Forecastle.

A hot upgrade only helps when the node keeps running. A crash, a host reboot
or a change of the Erlang VM still stops the calls on that node. For those
cases, see [durable calls](../../features/durable-calls/), which keep the
media in the SFU and the call state in a store.

## What AudioFlow provides

- `appup.exs`: AudioFlow's upgrade instructions. Forecastle compiles it to
  `audio_flow.appup` in the application `ebin` directory, and a Castle release
  copies it into the release.
- `@vsn` and an explicit `code_change/3` in each stateful process:
  `AudioFlow.Session`, `AudioFlow.Worker`, `AudioFlow.Duplex`,
  `AudioFlow.WebRTC`, `AudioFlow.WebRTC.Session` and
  `AudioFlow.WebRTC.Transport`.
- `test/hot_upgrade_test.exs`, which suspends a session and a worker in the
  middle of a request, loads their code again, runs `code_change/3` and
  checks that the request completes on the old code and the next one runs on
  the new code.

## Set up the host release

Add Castle to the application that builds the release, and customize the
release:

```elixir
def deps do
  [
    {:audio_flow, "~> 0.1"},
    {:castle, "~> 1.3"}
  ]
end

defp releases do
  [
    my_agent: fn ->
      [
        include_executables_for: [:unix],
        upgrade_from: ["tar:artifacts/my_agent-1.0.0.tar.gz"]
      ]
      |> Castle.customize()
    end
  ]
end
```

Write an appup for each application that you own, and point the project at
it with `appup: "appup.exs"` and `compilers: Mix.compilers() ++ [:appup]`.
`mix castle.appup` checks that an appup covers the changed modules, and
`mix castle.appup.gen` drafts missing entries.

Install a new version on the running node:

```sh
my_agent/bin/castle unpack 1.1.0
my_agent/bin/castle install 1.1.0
my_agent/bin/castle commit
```

A version is provisional until `commit`. A restart before `commit` returns to
the previous permanent version.

## Change process state

Each stateful module has a state version:

```elixir
@vsn 1

@impl true
def code_change(_old_vsn, state, _extra), do: {:ok, state}
```

When a change adds, removes or renames a state key, increase `@vsn` and
migrate the old state:

```elixir
@vsn 2

@impl true
def code_change(1, state, _extra), do: {:ok, Map.put(state, :new_key, nil)}
def code_change({:down, 1}, state, _extra), do: {:ok, Map.delete(state, :new_key)}
```

Then add `{:update, Module, {:advanced, []}}` to the appup for that version,
in both the upgrade and the downgrade lists.

## Rules

- **Use remote functions in long-lived state.** A local `fn` stores a
  reference to the module version that made it. After two upgrades of that
  module, the fun is purged and a call to it fails with `:badfun`. Session
  options such as adapter `:run` functions live as long as the session. In
  modules that you upgrade often, prefer `&Module.function/arity` or
  `{module, options}` adapter tuples.
- **Turns finish on the old code.** A running turn task keeps the code it
  started with. The next turn uses the new code. Upgrades with
  `{:advanced, []}` or `soft_purge` wait for those tasks.
- **Restart for native code.** A change to a NIF dependency, such as
  `ex_webrtc`, `ex_libsrtp` or a Membrane plugin, needs a restart. Drain the
  node first.
- **Test the transition.** Use `Forecastle.UpgradeCase` and
  `Forecastle.Deployment` to start the shipped tarball, install the new
  version and check that live calls continue.
