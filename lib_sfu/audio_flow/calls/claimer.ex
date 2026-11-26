defmodule AudioFlow.Calls.Claimer do
  @moduledoc false
  # Renews the leases of local calls every lease_ms / 3, stops calls whose
  # leases another node took, and claims calls with expired leases.
  use GenServer
  require Logger
  alias AudioFlow.Calls
  alias AudioFlow.Calls.Call
  alias AudioFlow.CallStore

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def store, do: GenServer.call(__MODULE__, :store)
  def claim_now, do: GenServer.cast(__MODULE__, :claim)
  def drain, do: GenServer.call(__MODULE__, :drain, :infinity)

  @impl true
  def init(options) do
    send(self(), :tick)
    {:ok, %{options: options, draining: false, timer: nil}}
  end

  @impl true
  def handle_call(:store, _from, state), do: {:reply, state.options[:store], state}

  def handle_call(:drain, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timeout = state.options[:drain_timeout_ms]

    Calls.local()
    |> Enum.map(fn {_id, pid} -> Task.async(fn -> Call.drain(pid, timeout) end) end)
    |> Task.yield_many(timeout + 5_000)

    {:reply, :ok, %{state | draining: true, timer: nil}}
  end

  @impl true
  def handle_cast(:claim, %{draining: false} = state), do: {:noreply, claim(state)}
  def handle_cast(:claim, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, %{draining: false} = state) do
    state = state |> renew() |> claim()
    timer = Process.send_after(self(), :tick, max(div(state.options[:lease_ms], 3), 50))
    {:noreply, %{state | timer: timer}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp renew(state) do
    %{store: store, owner: owner, lease_ms: lease_ms} = Map.new(state.options)
    local = Calls.local()

    if local != [] do
      ids = Enum.map(local, &elem(&1, 0))

      case CallStore.renew(store, owner, ids, lease_ms) do
        {:ok, renewed} ->
          kept = MapSet.new(renewed, & &1.id)

          for {id, pid} <- local, id not in kept do
            Logger.warning("call #{id}: lease taken by another node, stopping")
            Call.lost(pid)
          end

        {:error, reason} ->
          Logger.warning("call lease renewal failed: #{inspect(reason)}")
      end
    end

    state
  end

  defp claim(state) do
    %{store: store, owner: owner, lease_ms: lease_ms, claim_limit: limit} = Map.new(state.options)

    case CallStore.claim(store, owner, lease_ms, limit) do
      {:ok, calls} ->
        for call <- calls, Calls.whereis(call.id) == nil, do: start(call, state.options)

      {:error, reason} ->
        Logger.warning("call claim failed: #{inspect(reason)}")
    end

    state
  end

  defp start(call, options) do
    case Calls.start_child(call, options) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        # Another node may be able to run it (for example, with the agent code).
        Logger.error("call #{call.id} did not start: #{inspect(reason)}")
        CallStore.release(options[:store], call.id, options[:owner])
    end
  end
end
