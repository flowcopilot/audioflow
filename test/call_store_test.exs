defmodule AudioFlow.CallStore.MemoryTest do
  use AudioFlow.Test.CallStoreContract, async: true
  alias AudioFlow.CallStore.Memory

  setup do
    {:ok, pid} = Memory.start_link()
    %{store: {Memory, pid}}
  end
end

# Needs a database: AUDIOFLOW_POSTGRES_URL=postgres://user:pass@host:port/db.
if System.get_env("AUDIOFLOW_POSTGRES_URL") do
  defmodule AudioFlow.CallStore.PostgresTest do
    use AudioFlow.Test.CallStoreContract, async: false
    alias AudioFlow.CallStore
    alias AudioFlow.CallStore.Postgres

    setup do
      uri = URI.parse(System.fetch_env!("AUDIOFLOW_POSTGRES_URL"))
      [user | password] = String.split(uri.userinfo || "postgres", ":", parts: 2)

      options = conn_options(uri, user, password)
      # Several connections, so that concurrent claims really run in parallel.
      conn = start_supervised!({Postgrex, Keyword.put(options, :pool_size, 4)})

      table = "audio_flow_calls_test_#{System.unique_integer([:positive])}"

      for sql <- String.split(Postgres.schema_sql(table), ";", trim: true),
          String.trim(sql) != "",
          do: Postgrex.query!(conn, sql, [])

      on_exit(fn ->
        {:ok, cleanup} =
          Postgrex.start_link(Keyword.delete(conn_options(uri, user, password), :name))

        Postgrex.query!(cleanup, "DROP TABLE #{table}", [])
        GenServer.stop(cleanup)
      end)

      %{store: {Postgres, connection: conn, table: table}}
    end

    defp conn_options(uri, user, password) do
      [
        hostname: uri.host,
        port: uri.port || 5432,
        database: String.trim_leading(uri.path, "/"),
        username: user,
        password: List.first(password)
      ]
    end

    test "a database error is not :stale, :not_found or :ok", %{store: {module, config}} do
      broken = {module, Keyword.put(config, :table, "audio_flow_calls_missing")}
      id = CallStore.uuid()

      assert {:error, %Postgrex.Error{}} = CallStore.get(broken, id)
      assert {:error, %Postgrex.Error{}} = CallStore.save(broken, id, "a", 0, %{turns: 1})
      assert {:error, %Postgrex.Error{}} = CallStore.renew(broken, "a", [id], 1_000)
      assert {:error, %Postgrex.Error{}} = CallStore.claim(broken, "a", 1_000, 10)
      assert {:error, %Postgrex.Error{}} = CallStore.release(broken, id, "a")
      assert CallStore.now(broken) > 0
    end

    test "concurrent claims split the calls", %{store: store} do
      ids =
        for _ <- 1..20,
            do: elem(CallStore.create(store, %{room: "r", agent: "A"}), 1).id

      claims =
        for owner <- ["a", "b", "c", "d"] do
          Task.async(fn -> CallStore.claim(store, owner, 60_000, 20) end)
        end
        |> Task.await_many()
        |> Enum.flat_map(fn {:ok, calls} -> Enum.map(calls, & &1.id) end)

      assert Enum.sort(claims) == Enum.sort(ids)
    end
  end
end
