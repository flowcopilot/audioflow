# From ui/: PGDATABASE=audioflow AUDIOFLOW_ML=1 mix run --no-start --no-halt examples/rag.exs
unless Code.ensure_loaded?(AudioFlow.Graph.Nodes.Models), do: raise("Build with AUDIOFLOW_ML=1")
System.fetch_env!("PGDATABASE")
{:ok, _} = Application.ensure_all_started(:audio_flow)

{:ok, _} =
  Supervisor.start_link([{Postgrex, name: AudioFlowUI.StarterDB}], strategy: :one_for_one)

Postgrex.query!(AudioFlowUI.StarterDB, "CREATE EXTENSION IF NOT EXISTS vector", [])

Postgrex.query!(
  AudioFlowUI.StarterDB,
  """
  CREATE TABLE IF NOT EXISTS audio_flow_documents (
    id text NOT NULL, collection text NOT NULL, content text NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}', embedding vector(384) NOT NULL,
    PRIMARY KEY (collection, id))
  """,
  []
)

content =
  "AudioFlow graphs connect typed nodes. Remote speech keys belong in the server environment."

adapter =
  AudioFlow.Graph.Nodes.Models.adapter(
    "text.embedding",
    %{model: "sentence-transformers/all-MiniLM-L6-v2"}
  )

:ok =
  AudioFlow.Adapter.run(adapter, content, fn vector ->
    Postgrex.query!(
      AudioFlowUI.StarterDB,
      """
      INSERT INTO audio_flow_documents (id, collection, content, embedding)
      VALUES ('starter-help', 'ui-starter', $1, $2::text::vector)
      ON CONFLICT (collection, id) DO UPDATE SET content = EXCLUDED.content, embedding = EXCLUDED.embedding
      """,
      [content, JSON.encode!(vector)]
    )

    :ok
  end)

Application.put_env(:audio_flow, :retrieval_profiles, %{
  "starter" => [
    dimensions: 384,
    backend:
      {AudioFlow.RAG.Pgvector,
       [connection: AudioFlowUI.StarterDB, collection: "ui-starter", timeout_ms: 5_000]}
  ]
})

config = Application.fetch_env!(:audio_flow_ui, AudioFlowUIWeb.Endpoint)
Application.put_env(:audio_flow_ui, AudioFlowUIWeb.Endpoint, Keyword.put(config, :server, true))
{:ok, _} = Application.ensure_all_started(:audio_flow_ui)
IO.puts("RAG ready at http://localhost:4100/examples; create the RAG graph there.")
