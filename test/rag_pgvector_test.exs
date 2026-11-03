defmodule AudioFlow.RAGPgvectorTest do
  use ExUnit.Case, async: false

  @moduletag skip: System.get_env("AUDIOFLOW_PGVECTOR_URL") == nil

  # Postgrex.start_link/1 expects connection fields; it does not parse :url.
  defp connection_options do
    uri = URI.parse(System.fetch_env!("AUDIOFLOW_PGVECTOR_URL"))

    [username, password] =
      String.split(uri.userinfo || "postgres:", ":", parts: 2)
      |> then(fn
        [user] -> [user, nil]
        pair -> pair
      end)

    [
      hostname: uri.host,
      port: uri.port || 5432,
      database: String.trim_leading(uri.path, "/"),
      username: URI.decode(username),
      password: if(password, do: URI.decode(password))
    ]
  end

  test "queries real pgvector with collection isolation and cosine ordering" do
    conn = start_supervised!({Postgrex, connection_options()})
    Postgrex.query!(conn, "CREATE EXTENSION IF NOT EXISTS vector", [])

    Postgrex.query!(
      conn,
      "CREATE TEMP TABLE audio_flow_documents (id text, collection text, content text, metadata jsonb, embedding vector(3))",
      []
    )

    for {id, collection, vector} <- [
          {"close", "a", "[1,0,0]"},
          {"far", "a", "[0,1,0]"},
          {"hidden", "b", "[1,0,0]"}
        ] do
      Postgrex.query!(
        conn,
        "INSERT INTO audio_flow_documents VALUES ($1, $2, $1, '{}'::jsonb, $3::text::vector)",
        [id, collection, vector]
      )
    end

    assert {:ok, [%{id: "close", distance: distance}]} =
             AudioFlow.RAG.Pgvector.retrieve([1, 0, 0],
               connection: conn,
               collection: "a",
               limit: 5,
               max_distance: 0.5
             )

    assert_in_delta distance, 0, 0.0001

    # Real backend rows cross the compiled graph boundary into the LLM context.
    graph = %{
      nodes: [
        %{id: "in", type: "input.text"},
        %{id: "embed", type: "acceptance.vector"},
        %{id: "retrieve", type: "rag.retrieve", options: %{profile: "acceptance"}},
        %{id: "llm", type: "demo.llm"}
      ],
      edges: [
        %{from: "in", to: "embed"},
        %{from: "embed", to: "retrieve"},
        %{from: "retrieve", to: "llm"}
      ]
    }

    # Compile using the real retrieval node and a trusted server-side profile.
    previous = Application.get_env(:audio_flow, :retrieval_profiles)

    Application.put_env(:audio_flow, :retrieval_profiles, %{
      "acceptance" => [
        dimensions: 3,
        backend: {AudioFlow.RAG.Pgvector, connection: conn, collection: "a"},
        max_distance: 0.5
      ]
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:audio_flow, :retrieval_profiles, previous),
        else: Application.delete_env(:audio_flow, :retrieval_profiles)
    end)

    {:ok, options} =
      AudioFlow.Graph.session_options(
        graph,
        AudioFlow.Graph.catalog([
          AudioFlow.Graph.Nodes.Input,
          AudioFlow.Graph.Nodes.Demo,
          AudioFlow.Graph.Nodes.RAG,
          __MODULE__.EmbeddingFixture
        ])
      )

    {:ok, session} = AudioFlow.start_session(options)
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    {:ok, turn} = AudioFlow.submit(session, %AudioFlow.Text{data: "find close"})
    assert_receive {AudioFlow, ^session, ^turn, {:text, documents, "retrieve"}}
    assert [%{"id" => "close"}] = JSON.decode!(documents)
    assert_receive {AudioFlow, ^session, ^turn, {:text, response, "llm"}}
    assert response =~ "close"
    refute response =~ "hidden"
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}

    assert {:ok, []} =
             AudioFlow.RAG.Pgvector.retrieve([1, 0, 0],
               connection: conn,
               collection: "missing",
               limit: 5,
               max_distance: 2.0
             )
  end

  defmodule EmbeddingFixture do
    @behaviour AudioFlow.Graph.Node
    def nodes,
      do: [
        %{
          type: "acceptance.vector",
          title: "Fixture vector",
          description: "Synthetic embedding, real retrieval",
          input: :text,
          output: :vector,
          options: []
        }
      ]

    def adapter(_, _), do: {AudioFlow.Adapters.Function, run: fn _, emit -> emit.([1, 0, 0]) end}
  end
end
