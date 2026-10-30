---
title: Conversation history
description: Keep earlier turns in the prompt, with limits on turns and bytes.
sidebar:
  order: 2
---

Enable history when the language model adapter accepts chat messages:

```elixir
{:ok, session} = AudioFlow.start_session(
  Keyword.put(session_options, :history, [max_turns: 8, max_bytes: 16_384]))
```

`history: true` uses these defaults. History is disabled by default, so
existing adapters continue to receive one transcript string.

## Message format

With history enabled, the language model receives a list of
`%{role: :user | :assistant, content: text}` maps. Saved user and assistant
pairs precede the current user message. `Prompt.qwen3/2` and
`Adapters.ChatHTTP` accept this format. Custom adapters and routing functions
must accept the message list when history is enabled. System instructions stay
in the model adapter or prompt formatter.

## Limits

`max_turns` counts complete saved pairs. `max_bytes` counts UTF-8 text content.
The runtime removes the oldest complete pairs to fit the new prompt. It also
removes old pairs when a successful reply makes saved history exceed a limit.

Current input and reply text must fit as one pair. Excess text ends the turn
with `{:error, :context_limit, metrics}`. The budget excludes role fields,
prompt delimiters, and system instructions. It is a byte limit, not a model
token limit. Set model sequence limits for the chosen workload.

## What is saved

Only nonempty user and assistant text becomes a saved pair. The session saves
it after successful inference and acknowledgement from `Output.finish/2`.
Failed or cancelled turns leave the previous saved pairs intact. A cancellation
after `:done` flushes output and keeps that completed pair. Each session owns
its history, also when sessions share the same inference worker.

Image descriptions use the user role, so later voice turns can refer to the
described image. History stores text, not raw image or audio data.

## Clear history

Clear the saved text while the session is idle:

```elixir
:ok = AudioFlow.clear_history(session)
```

An active turn returns `{:error, :busy}`. History lasts for the session
process; owner exit or a session crash ends it.

## Try it

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_HISTORY=1 AUDIOFLOW_LLM=Qwen/Qwen3-0.6B \
  mix run examples/conversation.exs output first.s16le second.s16le
```

Inputs are mono 16 kHz s16le PCM. The example loads shared models once and
writes one PCM file plus JSON metadata per turn.
