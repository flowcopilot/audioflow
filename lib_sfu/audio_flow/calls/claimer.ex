defmodule AudioFlow.Calls.Claimer do
  @moduledoc false
  # Renews the leases of local calls every lease_ms / 3, stops calls whose
  # leases another node took, and claims calls with expired leases. A drain
  # runs in its own process, so the renewals go on while the calls hand over.
  use GenServer
  require Logger
  alias AudioFlow.Calls
  alias AudioFlow.Calls.Call
  alias AudioFlow.CallStore

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  # The store is in the registry metadata, so reading it does not wait for a
  # claim or a renewal.
  def store do
    {:ok, store} = Registry.meta(AudioFlow.Calls.Registry, :store)
    store
  end

  def claim_now, do: GenServer.cast(__MODULE__, :claim)
  def drain, do: GenServer.call(__MODULE__, :drain, :infinity)

  @impl true
  def init(options) do
    Registry.put_meta(AudioFlow.Calls.Registry, :store, options[:store])
    send(self(), :tick)
    {:ok, %{options: options, draining: false, drain: nil, timer: nil}}
  end

  @impl true
  def handle_call(:drain, from, %{drain: nil} = state) do
    timeout = state.options[:drain_timeout_ms]
    calls = Calls.local()
    # Not linked: a drain that exits must not stop the claimer, which would
    # restart and claim calls again.
    {_pid, ref} = spawn_monitor(fn -> drain_all(calls, timeout) end)
    {:noreply, %{state | draining: true, drain: {ref, [from]}}}
  end

  def handle_call(:drain, from, %{drain: {ref, froms}} = state),
    do: {:noreply, %{state | drain: {ref, [from | froms]}}}

  def handle_call(:drain, _from, %{drain: :done} = state), do: {:reply, :ok, state}

  @impl true
  def handle_cast(:claim, state), do: {:noreply, claim(state)}

  @impl true
  def handle_info(:tick, state) do
    state = state |> renew() |> claim()
    timer = Process.send_after(self(), :tick, max(div(state.options[:lease_ms], 3), 50))
    {:noreply, %{state | timer: timer}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{drain: {ref, froms}} = state) do
    for from <- froms, do: GenServer.reply(from, :ok)
    {:noreply, %{state | drain: :done}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp drain_all([], _timeout), do: :ok

  defp drain_all(calls, timeout) do
    calls
    |> Task.async_stream(fn {id, pid} -> drain_call(id, pid, timeout) end,
      max_concurrency: length(calls),
      timeout: timeout + 10_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.run()
  end

  defp drain_call(id, pid, timeout) do
    case Call.drain(pid, timeout) do
      :ok -> :ok
      {:error, reason} -> Logger.error("call #{id}: drain failed: #{inspect(reason)}")
    end
  catch
    :exit, reason -> Logger.warning("call #{id}: drain did not finish: #{inspect(reason)}")
  end

  defp renew(state) do
    %{store: store, owner: owner, lease_ms: lease_ms} = Map.new(state.options)

    case Calls.local() do
      [] ->
        :ok

      local ->
        case CallStore.renew(store, owner, Enum.map(local, &elem(&1, 0)), lease_ms) do
          {:ok, renewed} -> stop_lost(local, MapSet.new(renewed))
          {:error, reason} -> Logger.warning("call lease renewal failed: #{inspect(reason)}")
        end
    end

    state
  end

  defp stop_lost(local, kept) do
    for {id, pid} <- local, id not in kept do
      Logger.warning("call #{id}: lease taken by another node, stopping")
      Call.lost(pid)
    end
  end

  # No claims during a drain: this node is stopping.
  defp claim(%{draining: true} = state), do: state

  defp claim(state) do
    %{store: store, owner: owner, lease_ms: lease_ms, claim_limit: limit} = Map.new(state.options)
    # A call that runs here keeps its lease by renewal. A claim of it would
    # change its version, and its next save would fail.
    local = Enum.map(Calls.local(), &elem(&1, 0))

    case CallStore.claim(store, owner, lease_ms, limit, local) do
      {:ok, calls} ->
        for call <- calls, Calls.whereis(call.id) == nil, do: start(call, state.options)

      {:error, reason} ->
        Logger.warning("call claim failed: #{inspect(reason)}")
    end

    state
  end

  # The call joins after it starts, so this returns at once. A call that does
  # not start keeps its lease and is not renewed: the lease expires, and a
  # claim finds the call again. That is the back-off.
  defp start(call, options) do
    case Calls.start_child(call, options) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.error("call #{call.id} did not start: #{inspect(reason)}")
    end
  end
end
