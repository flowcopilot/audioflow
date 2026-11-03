# ReqLLM execution in AudioFlow

Use `{AudioFlow.Adapters.ReqLLM, model: model, ...req_llm_options}` for HTTP
inference. The input is a ReqLLM context, message list or prompt. AudioFlow's
`:audio_flow` keyword contains execution limits and Jido tools; native ReqLLM
`:tools` remain at the top level. See the README for examples and migration.
`llm.req_llm` is the graph node; `llm.chat_http` remains a deprecated migration
node. The native Nx path does not use ReqLLM.

## Dependency selection

The root project pins the compatible minor line `~> 1.29.0`. ReqLLM 1.30.0
requires Zoi 0.19, which conflicts with Jido 2.4's Zoi 0.18 constraint. Hex
reported a WebSocket TLS advisory for 1.28.0; 1.29.0 resolves without that
advisory. No dependency override or Jido upgrade was introduced.

Verified against the official [StreamResponse documentation](https://req-llm.hexdocs.pm/ReqLLM.StreamResponse.html),
[StreamServer documentation](https://req-llm.hexdocs.pm/ReqLLM.StreamServer.html)
and [ReqLLM 1.29 source](https://github.com/agentjido/req_llm/tree/v1.29.0/lib/req_llm).
Context7 lookup was unavailable because the sandbox could not resolve its npm
host; official docs and fetched package source supplied the API evidence.

## Why the execution bridge owns socket reads

ReqLLM's StreamResponse/StreamServer pipeline has consumer monitors and a
500-chunk default high watermark. It suspends the synchronous producer call
until the queue drains, but one transport event can decode to more than the
watermark. Its public orchestration does not expose a raw response byte limit
or bounded SSE parser fields. These are required by AudioFlow.

AudioFlow therefore calls ReqLLM's provider dispatch and `attach_stream`, uses
its SSE parser, provider decoder and `Provider.ChunkAccumulator`, and performs
Finch `stream_while` in the turn itself. It has no StreamServer, producer task,
metadata handle or output queue. A blocked emit callback blocks further reads.
Killing the turn closes the checked-out HTTP/1 socket through Finch ownership;
cleanup does not depend on an `after` block. Existing session cancellation,
consumer throw and idle-timeout tests verify closure, and the direct bridge test
kills a process blocked in emit and observes both process death and remote TCP
closure. Linked tool tasks die with their turn.

The bridge enforces request, response, retained/completed SSE event and text
byte budgets. Text budgets span tool rounds and filler. Tool calls, rounds,
execution time and result sizes remain bounded. Each request runs once without
retry, redirect, cache or fixture replay. Native ReqLLM HTTP timeout names
(`request_timeout`, `receive_timeout`, `pool_timeout`) are accepted; AudioFlow's
namespaced limits take precedence. Use the session deadline for wall-clock
limits including tools and blocked callbacks.

## Intentional limits and compatibility

This is an HTTP SSE execution bridge, rather than ReqLLM's full orchestration
surface. WebSocket, in-process, binary event-stream transports, dynamic model
resolvers and non-text output operations are outside its scope. Generation
options are interpreted by ReqLLM; orchestration options such as retry, cache,
telemetry, `on_finch_request`, custom connection pools and fixture capture are
not executed by this bridge. TLS and connection settings come from AudioFlow's
shared Finch pool. Pass custom request headers with `req_http_options: [headers: ...]`.

A narrow OpenAI validation guard rejects fields ReqLLM intentionally ignores
(refusal, legacy function calls, malformed calls and invalid finish states).
ReqLLM 1.29 drops function-name continuation fragments; AudioFlow retains only
those name fragments, while upstream owns arguments, text and JSON assembly.
Malformed arguments reported by the upstream accumulator must never execute a
tool. OpenAI completion requires a finish reason and `[DONE]`; other providers
use their terminal event. OpenAI-compatible and Anthropic decoding are tested
against local TCP fixtures. Live provider credentials were not available.

The deprecated ChatHTTP shim maps the old options to ReqLLM, without retaining
an HTTP implementation. ReqLLM now controls token field choice, usage streaming,
empty assistant content, tool-result names and argument JSON normalization.
The tests assert these equivalent wire changes while preserving cancellation,
size limits, refusal, truncation, tool execution and stream-completeness checks.
