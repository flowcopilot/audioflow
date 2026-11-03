defmodule AudioFlow.PacketWorker do
  @moduledoc false
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def request(worker, data, timeout) do
    GenServer.call(worker, {:request, data, timeout}, timeout + 1000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(options) do
    executable = Keyword.fetch!(options, :executable) |> Path.expand()
    args = Keyword.get(options, :args, []) |> Enum.map(&String.to_charlist/1)

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        {:packet, 4},
        :exit_status,
        args: args
      ])

    receive do
      {^port, {:data, "ready"}} -> {:ok, port}
      {^port, {:exit_status, status}} -> {:stop, {:worker_exit, status}}
    after
      Keyword.get(options, :startup_timeout, 30_000) ->
        Port.close(port)
        {:stop, :startup_timeout}
    end
  end

  @impl true
  def handle_call({:request, data, timeout}, _from, port) do
    Port.command(port, data)

    receive do
      {^port, {:data, response}} -> {:reply, {:ok, response}, port}
      {^port, {:exit_status, status}} -> {:stop, :normal, {:error, {:worker_exit, status}}, nil}
    after
      timeout ->
        Port.close(port)
        {:stop, :normal, {:error, :timeout}, nil}
    end
  end

  @impl true
  def handle_info({_port, {:exit_status, _}}, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, port) do
    if is_port(port) and Port.info(port), do: Port.close(port)
    :ok
  end
end
