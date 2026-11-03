defmodule AudioFlow.RAGPgvectorTest do
  use ExUnit.Case, async: false

  @moduletag skip: System.get_env("AUDIOFLOW_PGVECTOR_URL") == nil

  test "queries real pgvector with collection isolation and cosine ordering" do
    {:ok, conn} = Postgrex.start_link(url: System.fetch_env!("AUDIOFLOW_PGVECTOR_URL"))
    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)
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

    assert {:ok, []} =
             AudioFlow.RAG.Pgvector.retrieve([1, 0, 0],
               connection: conn,
               collection: "missing",
               limit: 5,
               max_distance: 2.0
             )
  end
end
