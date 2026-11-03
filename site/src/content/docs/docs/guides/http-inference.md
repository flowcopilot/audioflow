---
title: HTTP language models
description: Stream replies from llama.cpp or any ReqLLM provider.
sidebar:
  order: 4
---

`AudioFlow.Adapters.ReqLLM` runs HTTP language models through
[ReqLLM](https://hexdocs.pm/req_llm). It takes ReqLLM's model, context, and
generation options directly. It groups the generated text into sentences, with
whitespace preserved, and runs tools in the turn. It uses the same adapter
interface as the native models, and needs no native model dependencies.

```elixir
llm = {AudioFlow.Adapters.ReqLLM,
  model: %{provider: :openai, id: "audioflow-qwen"},
  base_url: "http://127.0.0.1:18082/v1",
  api_key: "local",
  system_prompt: AudioFlow.Prompt.default_system(),
  temperature: 0.0, max_tokens: 64}
{:ok, session} = AudioFlow.start_session(
  Keyword.put(session_options, :llm, llm))
```

## Options

Use a ReqLLM catalog model such as `"anthropic:claude-sonnet-4-5"`, or an inline
model such as `%{provider: :openai, id: "..."}` with `:base_url` for a local
OpenAI-compatible server. `:base_url`, `:api_key`, `:system_prompt`,
`:temperature`, `:max_tokens`, `:provider_options`, `:req_http_options`, and
native `ReqLLM.Tool` definitions are ReqLLM options. Resolve credentials when
you build the options, or use ReqLLM's provider credential configuration. Pass
custom request headers with `req_http_options: [headers: ...]`.

The adapter adds no system prompt. Pass `:system_prompt`;
`AudioFlow.Prompt.default_system/0` requests one short spoken sentence.

Input can be a `ReqLLM.Context`, a list of messages, or one string. Session
[history](../history/) passes a list of messages.

Settings that belong to AudioFlow go under the `:audio_flow` keyword: tools,
tool limits, and the byte and time limits below.

## Limits

The adapter reads the HTTP stream in the turn process. It uses ReqLLM's request
builders, SSE parser, provider decoders, and chunk accumulator, but not ReqLLM's
stream server. The shared Finch pool uses HTTP/1, so the output callback applies
back pressure to socket reads. Cancellation closes the active connection.

Each request runs once. The adapter does not follow redirects, retry, use
ReqLLM's cache, or replay fixtures. Only HTTP SSE transports are supported, not
ReqLLM's WebSocket or in-process transports.

These limits go under `:audio_flow`:

| Option | Default | Bound |
| --- | ---: | --- |
| `max_request_bytes` | 65,536 | Encoded request body |
| `max_response_bytes` | 262,144 | Complete response body |
| `max_event_bytes` | 16,384 | One SSE event |
| `max_text_bytes` | 8,192 | Generated text, across tool rounds |
| `timeout_ms` | 30,000 | Budget for response reads |
| `receive_timeout_ms` | 10,000 | Wait for a response chunk |
| `pool_timeout_ms` | 5,000 | Wait for a connection |

ReqLLM's `request_timeout`, `receive_timeout`, and `pool_timeout` options are
also accepted; the `:audio_flow` values take precedence. Use the session
deadline to bound the complete turn, including tools and a blocked callback.

Refusals, truncation, incomplete streams, invalid events, and empty replies
return errors. Earlier complete sentences can already have reached speech
synthesis. OpenAI-compatible streams need a finish reason and `[DONE]` before
the last text is emitted.

## Tool calls

Put Jido actions and `AudioFlow.Tool` maps under `audio_flow: [tools: ...]`. A
tool map has `:name`, `:description`, `:parameters` (JSON Schema), and a
one-argument `:run` function. Native `ReqLLM.Tool` structs go in the top-level
`:tools` option. Tool names must be unique.

```elixir
llm = {AudioFlow.Adapters.ReqLLM,
  model: "anthropic:claude-sonnet-4-5",
  system_prompt: AudioFlow.Prompt.default_system(),
  audio_flow: [
    tools: [MyApp.Actions.Weather],
    tool_context: %{user_id: user_id},
    tool_filler: "One moment."]}
```

Tools run in tasks linked to the turn, so cancellation stops a running tool.
The results go back to the model in a new request. If the model calls a tool
without first saying something, `:tool_filler` is spoken while the tool runs.
Tool failures, timeouts (`:tool_timeout_ms`, 10,000), and oversized results
(`:max_tool_result_bytes`, 8,192) go back to the model as errors.
`:max_tool_rounds` (4) limits the requests in one turn, and `:max_tool_calls`
(8) limits the calls in one request.

## Graph node

In graphs, use the `llm.req_llm` node. Its options are `model` (a
`provider:model` string), `base_url`, `system_prompt`, `api_key_env` (the name
of the environment variable, never the key), `tools_profile`, and `timeout_ms`.
The graph runner passes the session and turn to the tools as `tool_context`.

## Migrate from ChatHTTP

`AudioFlow.Adapters.ChatHTTP` and the `llm.chat_http` node are deprecated. The
adapter now only maps its old options to `AudioFlow.Adapters.ReqLLM`:

| ChatHTTP | ReqLLM |
| --- | --- |
| `endpoint: ".../v1/chat/completions"` | `base_url: ".../v1"` |
| `model: "id"` | `model: %{provider: :openai, id: "id"}` |
| `system:` | `system_prompt:` |
| `parameters: %{temperature:, max_tokens:}` | `temperature:`, `max_tokens:` |
| `headers:` | `req_http_options: [headers: ...]` |
| `tools:`, `tool_filler:`, limits | the same keys under `:audio_flow` |

Other `:parameters` entries raise an error; set them as ReqLLM generation or
provider options. ReqLLM now chooses the token field name, enables usage
streaming, omits `n: 1`, and normalizes tool argument JSON.

## Run

```sh
AUDIOFLOW_CHAT_ENDPOINT=http://127.0.0.1:18082/v1/chat/completions \
  AUDIOFLOW_LLM=audioflow-qwen mix run examples/http.exs "Say hello."
```

Set `AUDIOFLOW_CHAT_API_KEY` when the server needs authentication. To use HTTP
language inference with native Whisper and Kokoro, set
`AUDIOFLOW_LLM_ENGINE=http` and `AUDIOFLOW_CHAT_ENDPOINT` for
`examples/local.exs` or `examples/media.exs`.
