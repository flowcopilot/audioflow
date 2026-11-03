defmodule AudioFlow.RAGTest do
  use ExUnit.Case, async: false
  alias AudioFlow.RAG.{Retrieve, Pgvector}

  defmodule Backend do
    @behaviour AudioFlow.RAG.Backend
    def retrieve(vector, options) do
      send(Keyword.fetch!(options, :owner), {:retrieved, vector, options[:limit]})
      Keyword.fetch!(options, :result)
    end
  end

  defmodule EmbeddingFixture do
    @behaviour AudioFlow.Graph.Node
    def nodes do
      [
        %{
          type: "fixture.vector",
          title: "Fixture",
          description: "No model inference",
          input: :text,
          output: :vector,
          options: []
        }
      ]
    end

    def adapter(_, _), do: {AudioFlow.Adapters.Function, run: fn _, emit -> emit.([1, 0, 0]) end}
  end

  defp options(result) do
    [dimensions: 3, backend: {Backend, owner: self(), result: result}]
  end

  test "uses actual backend results including empty results and errors" do
    doc = %{id: "source", content: "document", metadata: %{}, distance: 0.1}

    assert :ok =
             Retrieve.run([1, 2, 3], options({:ok, [doc]}), fn text ->
               assert [%{"id" => "source", "content" => "document"}] = JSON.decode!(text)
               :ok
             end)

    assert_receive {:retrieved, [1, 2, 3], 5}
    assert :ok = Retrieve.run([1, 0, 0], options({:ok, []}), fn "[]" -> :ok end)

    assert {:error, :offline} =
             Retrieve.run([1, 0, 0], options({:error, :offline}), fn _ -> flunk() end)
  end

  test "rejects wrong dimensions, zero vectors, limits and oversized context" do
    for vector <- [[1], [0, 0, 0], ["x", 1, 2]] do
      assert {:error, :invalid_embedding} =
               Retrieve.run(vector, options({:ok, []}), fn _ -> flunk() end)
    end

    assert {:error, :invalid_retrieval_limits} =
             Retrieve.run([1, 0, 0], [limit: -1] ++ options({:ok, []}), fn _ -> flunk() end)

    assert {:error, :retrieval_too_large} =
             Retrieve.run([1, 0, 0], [max_bytes: 1] ++ options({:ok, []}), fn _ -> flunk() end)

    assert_receive {:retrieved, [1, 0, 0], 5}
    refute_receive {:retrieved, _, _}
  end

  test "pgvector binds vector, collection, limit and distance separately" do
    owner = self()

    query = fn :connection, sql, params, opts ->
      send(owner, {:sql, sql, params, opts})
      {:ok, %{rows: [["1", "real row", %{}, 0.25]]}}
    end

    assert {:ok, [%{content: "real row", distance: 0.25}]} =
             Pgvector.retrieve([1, 2, 3],
               connection: :connection,
               collection: "x'; DROP TABLE users; --",
               limit: 4,
               max_distance: 0.5,
               query: query
             )

    assert_receive {:sql, sql, ["[1,2,3]", collection, 4, 0.5], [timeout: 5_000]}
    assert collection =~ "DROP"
    refute sql =~ "DROP"
    assert sql =~ "ORDER BY embedding <=> $1::text::vector"
  end

  test "retrieval node is registered with vector input and text output" do
    {_, spec} = AudioFlow.Graph.catalog()["rag.retrieve"]
    assert spec.input == :vector
    assert spec.output == :text
  end

  test "graph runs vector retrieval and joins original question with returned documents" do
    previous = Application.get_env(:audio_flow, :retrieval_profiles)

    doc = %{
      id: "policy",
      content: "Returns accepted within 30 days",
      metadata: %{source: "handbook"},
      distance: 0.1
    }

    Application.put_env(:audio_flow, :retrieval_profiles, %{"test" => options({:ok, [doc]})})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:audio_flow, :retrieval_profiles, previous),
        else: Application.delete_env(:audio_flow, :retrieval_profiles)
    end)

    graph = %{
      nodes: [
        %{id: "input", type: "input.text"},
        %{id: "embedding", type: "fixture.vector"},
        %{id: "retrieve", type: "rag.retrieve", options: %{profile: "test"}},
        %{id: "llm", type: "demo.llm"}
      ],
      edges: [
        %{from: "input", to: "embedding"},
        %{from: "embedding", to: "retrieve"},
        %{from: "input", to: "llm"},
        %{from: "retrieve", to: "llm"}
      ]
    }

    catalog =
      AudioFlow.Graph.catalog([
        AudioFlow.Graph.Nodes.Input,
        AudioFlow.Graph.Nodes.Demo,
        AudioFlow.Graph.Nodes.RAG,
        EmbeddingFixture
      ])

    {:ok, opts} = AudioFlow.Graph.session_options(graph, catalog)
    {:ok, session} = AudioFlow.start_session(opts)
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    {:ok, ref} = AudioFlow.submit(session, %AudioFlow.Text{data: "Return policy?"})
    assert_receive {AudioFlow, ^session, ^ref, {:text, documents, "retrieve"}}
    assert [%{"id" => "policy"}] = JSON.decode!(documents)
    assert_receive {AudioFlow, ^session, ^ref, {:text, reply, "llm"}}
    assert reply =~ "Return policy?"
    assert reply =~ "Returns accepted within 30 days"
    assert_receive {AudioFlow, ^session, ^ref, {:done, _}}
  end
end
