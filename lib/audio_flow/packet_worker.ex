defmodule AudioFlow.PacketWorker do
  @moduledoc false
  # Owns one `{:packet, 4}` port program that answers every request with exactly
  # one packet, in order. The protocol has no request ids, so the worker counts
  # requests that timed out (`stale`) and drops that many late packets before it
  # accepts a response. If late packets back up (more than `@max_stale`), the
  # program is stuck: the worker closes the port and opens a fresh one.
  #
  # Requests carry a deadline on the worker's local monotonic clock. A request
  # whose deadline has passed, or whose caller is gone, is answered without being
  # sent to the program, so one slow call cannot fill the queue with dead work.
  # The worker itself never stops because of a timeout or a program exit.
  use GenServer

  @max_stale 1
  @call_grace 50

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def request(worker, data, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    GenServer.call(worker, {:request, data, deadline}, timeout + @call_grace)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(options) do
    state = %{
      port: nil,
      stale: 0,
      executable: Keyword.fetch!(options, :executable) |> Path.expand(),
      args: Keyword.get(options, :args, []) |> Enum.map(&String.to_charlist/1),
      startup_timeout: Keyword.get(options, :startup_timeout, 30_000)
    }

    case open(state) do
      {:ok, port} -> {:ok, %{state | port: port}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, data, deadline}, {caller, _}, state) do
    if expired?(deadline, caller) do
      {:reply, {:error, :timeout}, state}
    else
      case ensure_port(state) do
        {:ok, state} -> exchange(state, data, deadline)
        {:error, reason, state} -> {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_continue(:restart, %{port: nil} = state) do
    case open(state) do
      {:ok, port} -> {:noreply, %{state | port: port}}
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_continue(:restart, state), do: {:noreply, state}

  @impl true
  def handle_info({port, {:exit_status, _status}}, %{port: port} = state),
    do: {:noreply, %{state | port: nil, stale: 0}, {:continue, :restart}}

  # A late reply that arrives between requests settles one timed-out request.
  def handle_info({port, {:data, _late}}, %{port: port, stale: stale} = state) when stale > 0,
    do: {:noreply, %{state | stale: stale - 1}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}), do: close(port)

  defp exchange(state, data, deadline) do
    # Opening a port can outlast the deadline; do not send what nobody awaits.
    if remaining(deadline) == 0 do
      {:reply, {:error, :timeout}, state}
    else
      send_packet(state.port, data)
      collect(state, deadline)
    end
  end

  defp collect(state, deadline) do
    case await(state.port, deadline, state.stale) do
      {:ok, response} ->
        {:reply, {:ok, response}, %{state | stale: 0}}

      {:exit, status} ->
        {:reply, {:error, {:worker_exit, status}}, %{state | port: nil, stale: 0},
         {:continue, :restart}}

      {:timeout, stale} when stale > @max_stale ->
        close(state.port)
        {:reply, {:error, :timeout}, %{state | port: nil, stale: 0}, {:continue, :restart}}

      {:timeout, stale} ->
        {:reply, {:error, :timeout}, %{state | stale: stale}}
    end
  end

  defp await(port, deadline, stale) do
    receive do
      {^port, {:data, _late}} when stale > 0 -> await(port, deadline, stale - 1)
      {^port, {:data, response}} -> {:ok, response}
      {^port, {:exit_status, status}} -> {:exit, status}
    after
      remaining(deadline) -> {:timeout, stale + 1}
    end
  end

  defp send_packet(port, data) do
    Port.command(port, data)
  rescue
    # The program already exited; its exit status is in the mailbox.
    ArgumentError -> false
  end

  defp ensure_port(%{port: port} = state) when is_port(port), do: {:ok, state}

  defp ensure_port(state) do
    case open(state) do
      {:ok, port} -> {:ok, %{state | port: port, stale: 0}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp open(state) do
    port =
      Port.open({:spawn_executable, String.to_charlist(state.executable)}, [
        :binary,
        {:packet, 4},
        :exit_status,
        args: state.args
      ])

    receive do
      {^port, {:data, "ready"}} -> {:ok, port}
      {^port, {:exit_status, status}} -> {:error, {:worker_exit, status}}
    after
      state.startup_timeout ->
        close(port)
        {:error, :startup_timeout}
    end
  rescue
    error in ErlangError -> {:error, {:spawn_failed, error.original}}
  end

  defp close(port) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    flush(port)
  end

  defp close(_), do: :ok

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp expired?(deadline, caller) do
    remaining(deadline) == 0 or not caller_alive?(caller)
  end

  defp caller_alive?(pid) when node(pid) == node(), do: Process.alive?(pid)
  defp caller_alive?(_), do: true

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
