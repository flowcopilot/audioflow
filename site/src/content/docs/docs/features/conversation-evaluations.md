---
title: Conversation evaluations
description: Scripted regression tests over real session turns.
---

`AudioFlow.Evaluation.Conversation` submits real text turns to a session owned
by the test process. Enable history when testing follow-up behavior. It waits
for completion before submitting the next turn and concatenates streamed reply
chunks. Replies can match an exact string, regex, or one-argument predicate.

```elixir
alias AudioFlow.Evaluation.Conversation

{tools, observer} = Conversation.observe_tools([
  %{name: "weather", run: fn %{"city" => city} -> {:ok, "Sunny in #{city}"} end}
])

{:ok, session} = AudioFlow.start_session(
  history: true,
  llm: {AudioFlow.Adapters.ReqLLM,
    base_url: "http://localhost:8080/v1",
    model: %{provider: :openai, id: "your-tool-capable-model"},
    api_key: "local",
    audio_flow: [tools: tools]}
)
on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)

results = Conversation.run!(session, [
  %{input: "Weather in Oslo?", reply: ~r/sunny/i,
    tools: [{"weather", %{"city" => "Oslo"}}]},
  %{input: "Which city did I ask about?", reply: ~r/Oslo/, tools: []}
], observer: observer, timeout_ms: 30_000)
assert length(results) == 2
```

Tool assertions compare the exact ordered list of executed tools and decoded
arguments per turn. `observe_tools/1` preserves tool behavior and Jido action
context; it does not replace tools with mocks. It sees actual executions, not
malformed or unknown calls rejected before execution. Use a fresh observer per
session; do not share wrapped tools across concurrent sessions. The test
process must own the session and observer. Unrelated mailbox messages remain
untouched. For graphs with several text-producing nodes, select the reply with
`node: "reply-node-id"`.

A failed/cancelled turn, submission error, timeout, or mismatched expectation
raises `ExUnit.AssertionError` with the step number. Timeout is a per-turn wall
clock deadline and cancels the turn. Results include raw nonterminal events and
terminal metrics for further assertions. The caller manages session cleanup.

The regression suite uses the existing local HTTP fixture to exercise real SSE
parsing, tool execution, follow-up requests, and session history without provider
credentials. Those fixtures verify protocol handling and assertions, not model
reasoning. Against an actual endpoint, model selection, availability, latency,
and nondeterminism are the test author's responsibility. No simulated-user LLM
or acoustic quality scoring is included.
