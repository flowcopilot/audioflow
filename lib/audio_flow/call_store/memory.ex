defmodule AudioFlow.CallStore.Memory do
  @moduledoc """
  In-memory call store for tests and single-node development. The calls are
  lost when the store process stops. Use `{AudioFlow.CallStore.Memory, pid}`
  or a registered name.
  """
  use Agent
  @behaviour AudioFlow.CallStore
  alias AudioFlow.CallStore

  def start_link(options \\ []),
    do: Agent.start_link(fn -> %{} end, Keyword.take(options, [:name]))

  @impl true
  def create(store, call) do
    call = CallStore.new_call(call)
    Agent.update(store, &Map.put(&1, call.id, call))
    {:ok, call}
  end

  @impl true
  def get(store, id) do
    case Agent.get(store, &Map.fetch(&1, id)) do
      {:ok, call} -> {:ok, call}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def save(store, id, owner, version, changes) do
    Agent.get_and_update(store, fn calls ->
      case calls do
        %{^id => %{version: ^version, lease_owner: ^owner} = call} ->
          call =
            call
            |> apply_changes(Map.take(changes, writable()))
            |> Map.update!(:version, &(&1 + 1))

          {{:ok, call}, Map.put(calls, id, call)}

        _ ->
          {{:error, :stale}, calls}
      end
    end)
  end

  @impl true
  def claim(store, owner, lease_ms, limit, exclude) do
    now = CallStore.now()

    Agent.get_and_update(store, fn calls ->
      claimed =
        calls
        |> Map.values()
        |> Enum.filter(&(&1.status == :active and expired?(&1, now) and &1.id not in exclude))
        |> Enum.take(limit)
        |> Enum.map(&lease(&1, owner, now + lease_ms))

      {{:ok, claimed}, Enum.reduce(claimed, calls, &Map.put(&2, &1.id, &1))}
    end)
  end

  @impl true
  def renew(store, owner, ids, lease_ms) do
    until = CallStore.now() + lease_ms

    Agent.get_and_update(store, fn calls ->
      renewed =
        for id <- ids,
            %{lease_owner: ^owner, status: :active} = call <- [calls[id]],
            do: %{call | lease_expires_at: until}

      {{:ok, Enum.map(renewed, & &1.id)}, Enum.reduce(renewed, calls, &Map.put(&2, &1.id, &1))}
    end)
  end

  @impl true
  def release(store, id, owner) do
    Agent.update(store, fn calls ->
      case calls do
        %{^id => %{lease_owner: ^owner} = call} ->
          Map.put(calls, id, %{call | lease_expires_at: CallStore.now()})

        _ ->
          calls
      end
    end)
  end

  defp apply_changes(call, changes) do
    case changes do
      %{history: {:append, entries}} ->
        Map.merge(call, %{changes | history: call.history ++ entries})

      _ ->
        Map.merge(call, changes)
    end
  end

  defp expired?(%{lease_expires_at: nil}, _now), do: true
  defp expired?(%{lease_expires_at: at}, now), do: at <= now

  # A claim is a write: it moves the version, which fences the old owner.
  defp lease(call, owner, until),
    do: %{call | lease_owner: owner, lease_expires_at: until, version: call.version + 1}

  defp writable,
    do: [:history, :conversation_state, :turns, :pending_input, :resume_token, :status]
end
