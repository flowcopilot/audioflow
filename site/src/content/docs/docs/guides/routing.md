---
title: Routing and workers
description: Bounded workers, model routes, and inference on other nodes.
sidebar:
  order: 7
---

`AudioFlow.Worker` runs an adapter with a fixed limit on active requests. It
rejects requests above that limit and keeps no waiting queue.
`AudioFlow.Router` sends each request to a worker on a named route.

```elixir
llm_adapter = {AudioFlow.NxAdapter,
  serving: AudioFlow.LLM,
  input: &AudioFlow.Prompt.qwen3/1,
  output: &AudioFlow.NxAdapter.sentences/1}

children = [
  {AudioFlow.Worker,
   name: MyApp.LocalLLM, adapter: llm_adapter,
   max_concurrency: 4, timeout_ms: 120_000},
  {AudioFlow.Router,
   name: MyApp.Routes,
   routes: %{voice: [MyApp.LocalLLM, {MyApp.RemoteLLM, :"ml@worker"}]}}
]
{:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

options = Keyword.put(session_options, :llm,
  {AudioFlow.Router, router: MyApp.Routes, route: :voice, timeout_ms: 120_000})
{:ok, session} = AudioFlow.start_session(options)
```

## Remote workers

The remote node must run AudioFlow and a worker named `MyApp.RemoteLLM`. Erlang
distribution must already connect the nodes. Use compatible code on trusted
nodes. Inputs and outputs cross the connection; model weights stay in their
shared services. A worker can use `NxAdapter` or an application adapter for
ONNX, llama.cpp, or a cloud API.

## Route selection

Routes rotate the starting worker for each request. A busy or unavailable
worker is skipped. An error after admission ends the request; the router does
not repeat partial speech on another worker. If all workers reject the request,
the caller receives `{:error, {:no_worker_available, route, reasons}}`.

Change a route while sessions stay open:

```elixir
AudioFlow.Router.put_route(MyApp.Routes, :voice, [{MyApp.RemoteLLM, :"ml@worker"}])
```

The change applies to later adapter calls. Active requests keep their worker.
An empty worker list disables the route. `:route` can also be a function that
selects a route key from the adapter input, for example by text length or
language.

## Cancellation

Each output chunk waits for its caller's acknowledgement. Caller exit and
session cancellation stop the worker task, also on a remote node. Worker exit or
node loss ends the active request with an error.

## Try it

```sh
mix run examples/routing.exs
AUDIOFLOW_DISTRIBUTED_TESTS=1 elixir --sname audioflow_test -S mix test
```

The distributed checks start a second local Erlang node. They check remote
output, cancellation, and node loss.
