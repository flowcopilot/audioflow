defmodule AudioFlow.Test.CallFlakyStore do
  @moduledoc false
  # A call store for tests. It wraps a memory store, reports each save to the
  # test process, and fails the saves while the flag Agent holds an error:
  # `{AudioFlow.Test.CallFlakyStore, memory: store, flag: agent, test: pid}`.
  @behaviour AudioFlow.CallStore
  alias AudioFlow.CallStore

  @doc "Makes the saves return `result` (`:ok` for no failure)."
  def fail_with({__MODULE__, config}, result), do: Agent.update(config[:flag], fn _ -> result end)

  @impl true
  def create(config, call), do: CallStore.create(config[:memory], call)

  @impl true
  def get(config, id), do: CallStore.get(config[:memory], id)

  @impl true
  def save(config, id, owner, version, changes) do
    send(config[:test], {:save, changes})

    case Agent.get(config[:flag], & &1) do
      :ok -> CallStore.save(config[:memory], id, owner, version, changes)
      error -> error
    end
  end

  @impl true
  def claim(config, owner, lease_ms, limit, exclude),
    do: CallStore.claim(config[:memory], owner, lease_ms, limit, exclude)

  @impl true
  def renew(config, owner, ids, lease_ms),
    do: CallStore.renew(config[:memory], owner, ids, lease_ms)

  @impl true
  def release(config, id, owner), do: CallStore.release(config[:memory], id, owner)
end
