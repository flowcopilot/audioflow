defmodule AudioFlow.Test.CallStoreContract do
  @moduledoc false
  # Shared tests for AudioFlow.CallStore implementations. The using module's
  # setup must put a store tuple under :store.
  use ExUnit.CaseTemplate
  alias AudioFlow.CallStore

  using do
    quote do
      alias AudioFlow.CallStore

      defp new_call(store),
        do: CallStore.create(store, %{room: "r", agent: "Elixir.Agent", metadata: %{"a" => 1}})

      test "a created call can be read back", %{store: store} do
        {:ok, call} = new_call(store)
        assert {:ok, ^call} = CallStore.get(store, call.id)
        assert %{status: :active, history: [], version: 0, metadata: %{"a" => 1}} = call
        assert {:error, :not_found} = CallStore.get(store, CallStore.uuid())
      end

      test "claims take expired calls once, and fence the previous owner", %{store: store} do
        {:ok, %{id: id}} = new_call(store)

        assert {:ok, [%{id: ^id, lease_owner: "a", version: v1}]} =
                 CallStore.claim(store, "a", 60_000, 100) |> only(id)

        assert {:ok, []} = CallStore.claim(store, "b", 60_000, 100) |> only(id)

        assert {:ok,
                %{version: v2, history: [{"hi", "hello"}], conversation_state: "intro", turns: 1}} =
                 CallStore.save(store, id, "a", v1, %{
                   history: [{"hi", "hello"}],
                   conversation_state: "intro",
                   turns: 1
                 })

        assert v2 == v1 + 1
        assert {:error, :stale} = CallStore.save(store, id, "a", v1, %{turns: 9})
        assert {:error, :stale} = CallStore.save(store, id, "b", v2, %{turns: 9})

        # A release lets another owner claim at once; the old owner is fenced.
        :ok = CallStore.release(store, id, "a")

        assert {:ok, [%{lease_owner: "b", version: v3}]} =
                 CallStore.claim(store, "b", 60_000, 100) |> only(id)

        assert {:error, :stale} = CallStore.save(store, id, "a", v2, %{turns: 2})
        assert {:ok, []} = CallStore.renew(store, "a", [id], 60_000)
        assert {:ok, [^id]} = CallStore.renew(store, "b", [id], 60_000)
        assert {:ok, %{turns: 1, history: [{"hi", "hello"}]}} = CallStore.get(store, id)
        assert {:ok, _} = CallStore.save(store, id, "b", v3, %{status: :ended})
        :ok = CallStore.release(store, id, "b")
        assert {:ok, []} = CallStore.claim(store, "c", 60_000, 100) |> only(id)
      end

      test "an expired lease can be claimed by another owner", %{store: store} do
        {:ok, %{id: id}} = new_call(store)
        {:ok, [_]} = CallStore.claim(store, "a", 1, 100) |> only(id)
        Process.sleep(20)
        assert {:ok, [%{lease_owner: "b"}]} = CallStore.claim(store, "b", 60_000, 100) |> only(id)
      end

      test "a claim leaves out the excluded calls", %{store: store} do
        {:ok, %{id: id}} = new_call(store)
        assert {:ok, []} = CallStore.claim(store, "a", 60_000, 100, [id]) |> only(id)
        assert {:ok, [%{id: ^id}]} = CallStore.claim(store, "a", 60_000, 100, []) |> only(id)
      end

      test "a save can append to the history", %{store: store} do
        {:ok, %{id: id}} = new_call(store)
        {:ok, [%{version: v1}]} = CallStore.claim(store, "a", 60_000, 100) |> only(id)

        assert {:ok, %{history: [{"a", "b"}], version: v2}} =
                 CallStore.save(store, id, "a", v1, %{history: {:append, [{"a", "b"}]}})

        assert {:ok, %{history: [{"a", "b"}, {"c", "d"}], turns: 2, version: v3}} =
                 CallStore.save(store, id, "a", v2, %{
                   history: {:append, [{"c", "d"}]},
                   turns: 2
                 })

        assert {:ok, %{history: [{"e", "f"}]}} =
                 CallStore.save(store, id, "a", v3, %{history: [{"e", "f"}]})

        assert {:ok, %{history: [{"e", "f"}]}} = CallStore.get(store, id)
      end

      test "the store clock is close to the clock of this node", %{store: store} do
        assert_in_delta CallStore.now(store), CallStore.now(), 5_000
      end

      # Other tests can share the store: keep only this test's call.
      defp only({:ok, calls}, id), do: {:ok, Enum.filter(calls, &(&1.id == id))}
    end
  end
end
