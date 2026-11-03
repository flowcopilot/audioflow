# Conversation states and retrieval

## Conversation and handoff

`AudioFlow.Graph.Conversation` orchestrates independently validated graph DAGs.
Conversation transitions can cycle; node edges still cannot. The same Session PID,
owner, output transport and saved user/assistant history survive a handoff. Each
state graph supplies its own prompt and tool profile. A handoff requested during a
turn is staged, then committed after successful output completion. Cancelled,
failed and timed-out turns discard staged transitions. The current turn finishes
using its original agent; the next turn uses the destination agent. This is not
mid-generation interruption or transfer of the provider's internal tool messages.

```elixir
alias AudioFlow.Graph.Conversation

# triage_graph and billing_graph are ordinary JSON-compatible AudioFlow graphs.
# Each must enable settings.history and have exactly one history-capable node.
flow = Conversation.new(
  %{"triage" => triage_graph, "billing" => billing_graph},
  "triage",
  %{{"triage", {:intent, "billing"}} => "billing",
    {"billing", {:tool_result, "resolved", :ok}} => "triage"}
)
{:ok, session} = Conversation.start_session(flow, owner: self())
AudioFlow.submit(session, %AudioFlow.Text{data: "Hello"})
# After your classifier selects the intent:
Conversation.event(session, {:intent, "billing"})
# After your application tool completes successfully:
Conversation.event(session, {:tool_result, "resolved", :ok})
Conversation.state(session)
```

Events match exact terms; no LLM classifier or intent inference is fabricated.
An unlisted event returns `{:error, :invalid_transition}`. Application callers can
use `Conversation.tool/3` for explicit tool-result transitions. For an LLM-selected
handoff, register the existing Jido-compatible action in trusted server config:

```elixir
config :audio_flow, :chat_tool_profiles, %{
  "triage" => [AudioFlow.Graph.Handoff],
  "billing" => [MyApp.ResolveInvoice]
}
```

Set the triage `llm.chat_http` node's `tools_profile` option to `"triage"`, its
`system` prompt to describe the billing intent, and the billing node's profile to
`"billing"`. The graph runner supplies `%{session: pid, turn: ref}` as tool context.
`AudioFlow.Graph.Handoff` accepts an `intent` string and stages `{:intent, intent}`.
It checks the turn reference so late tool results cannot affect another turn.
Your Jido action can likewise call
`GenServer.call(context.session, {:conversation_event, context.turn, event})`.
The transition map allowlists destinations; model output cannot select arbitrary
graphs or execute arbitrary modules. Do not expose trusted profile configuration
to untrusted clients.

Jido's installed `Jido.Agent.Strategy.FSM` is an **execution-phase** FSM, including
a required `processing` phase. Conversation states deliberately live above that
strategy, rather than treating an execution phase as an agent persona. Existing
Jido action execution through `AudioFlow.Tool` remains unchanged.

State plans compile once. Change a state's `system` and `tools_profile` before
constructing the conversation. Graph settings other than history do not override
session limits per state; set timeout and event limits on `start_session/2`.
The UI lists retrieval nodes, but conversation authoring/running currently uses
this Elixir API; the UI's single-graph run API is unchanged.

## pgvector retrieval

`text.embedding -> rag.retrieve` reuses the existing ML embedding node. The latter
has a vector input and text output (a JSON array with `id`, `content`, `metadata`,
`distance`). Add both `input.text -> llm` and `rag.retrieve -> llm` edges to join
the original question and context at the LLM; instruct its system prompt to treat
retrieved documents as untrusted data, cite document IDs, and admit absent context.
No matches emits `[]`; database errors fail the turn, never synthetic documents.
The ML profile is needed for local embeddings; retrieval itself is core-only.

Provision the extension and schema separately (not automatically at app startup):

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE audio_flow_documents (
  id text PRIMARY KEY,
  collection text NOT NULL,
  content text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}',
  embedding vector(384) NOT NULL
);
CREATE INDEX ON audio_flow_documents USING hnsw (embedding vector_cosine_ops);
CREATE INDEX ON audio_flow_documents (collection);
```

Start a supervised Postgrex connection in your host application, then configure:

```elixir
config :audio_flow, :retrieval_profiles, %{
  "support" => [
    dimensions: 384,
    max_distance: 0.6,
    backend: {AudioFlow.RAG.Pgvector,
      [connection: MyApp.VectorDB, collection: "support", timeout_ms: 5_000]}
  ]
}
```

Use node options `{"profile":"support","limit":5,"max_bytes":32768}`.
Profiles are allowlisted server configuration, never database credentials or
module names supplied by graph JSON. Missing profiles fail compilation rather
than silently falling back. Limits allow 1–100 documents; zero vectors and wrong
dimensions fail before querying; oversized context returns an explicit error.
Cosine distance ranges from 0 to 2. SQL binds vector text, collection, limit and
threshold as separate parameters. The fixed table/schema avoids identifier
interpolation and requires no custom Postgrex vector encoder. Results are ordered
by ascending cosine distance. Approximate HNSW filtering may return fewer matches;
tune pgvector's index/search settings for your dataset.

Ingestion is application-owned: chunk documents, embed each chunk with the **same
model, normalization, and dimensionality** used for queries, and insert content,
source metadata, collection and vector using parameterized SQL. Equal dimensions
do not establish model compatibility. This change does not download a corpus,
perform ingestion, claim retrieval quality, or infer missing embeddings.

Tests use deterministic backend and SQL-driver fakes. To run the real database
regression, supply a disposable PostgreSQL database with pgvector installed and
permission to create the extension and temporary tables:

```sh
AUDIOFLOW_PGVECTOR_URL=postgresql://localhost/audioflow_test mix test test/rag_pgvector_test.exs
```

That test creates only a temporary documents table and checks actual cosine
ordering, collection isolation, thresholds and empty results.

Protocol references: [pgvector](https://github.com/pgvector/pgvector),
[Postgrex parameterized query API](https://hexdocs.pm/postgrex/Postgrex.html#query/4),
[Jido FSM](https://hexdocs.pm/jido/Jido.Agent.Strategy.FSM.html).
