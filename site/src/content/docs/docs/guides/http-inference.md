---
title: HTTP language models
description: Stream chat completions from llama.cpp or a cloud endpoint.
sidebar:
  order: 4
---

`AudioFlow.Adapters.ChatHTTP` implements streaming chat completions for
compatible local servers and cloud endpoints. It uses the same adapter interface
as the native models. No native model dependencies are required.

```elixir
llm = {AudioFlow.Adapters.ChatHTTP,
  endpoint: "http://127.0.0.1:18082/v1/chat/completions",
  model: "audioflow-qwen",
  parameters: %{temperature: 0, max_tokens: 64}}
{:ok, session} = AudioFlow.start_session(
  Keyword.put(session_options, :llm, llm))
```

## Options

Supply the complete endpoint URL and the model ID that the server expects. Use
HTTPS for cloud endpoints. Set `:api_key` to a string or a zero-argument
function, for example `fn -> System.fetch_env!("AUDIOFLOW_CHAT_API_KEY") end`.
Additional `:headers` can hold provider options. The adapter does not follow
redirects or retry HTTP status errors.

Input can be one string or a list of chat messages. `:system` sets the system
instruction; its default requests one short spoken sentence. `:parameters`
holds provider-specific JSON fields. The adapter fixes `model`, `messages`,
`stream: true`, and `n: 1`. The default token limit is `max_tokens: 128`.

## Limits

The shared Finch pool uses HTTP/1, so the output callback applies back pressure
to socket reads. Cancellation closes the active connection.

| Option | Default | Bound |
| --- | ---: | --- |
| `max_request_bytes` | 65,536 | Encoded request body |
| `max_response_bytes` | 262,144 | Complete response body |
| `max_event_bytes` | 16,384 | One SSE event |
| `max_text_bytes` | 8,192 | Generated text |
| `timeout_ms` | 30,000 | Budget for response reads |
| `receive_timeout_ms` | 10,000 | Wait for a response chunk |
| `pool_timeout_ms` | 5,000 | Wait for a connection |

Truncation, incomplete streams, tool calls, refusals, invalid events, and empty
replies return errors. Earlier complete sentences can already have reached
speech synthesis. This adapter handles text chat only.

## Run

```sh
AUDIOFLOW_CHAT_ENDPOINT=http://127.0.0.1:18082/v1/chat/completions \
  AUDIOFLOW_LLM=audioflow-qwen mix run examples/http.exs "Say hello."
```

To use HTTP language inference with native Whisper and Kokoro, set
`AUDIOFLOW_LLM_ENGINE=http` and `AUDIOFLOW_CHAT_ENDPOINT` for
`examples/local.exs` or `examples/media.exs`.
