defmodule AudioFlow.Router do
  @moduledoc """
  Dynamic routes to bounded inference workers.

  Start with optional `:name` and `:routes`, a map from route keys to ordered
  lists of worker targets. Each request rotates the starting worker. Busy or
  unavailable workers are skipped. Once a worker accepts, errors are terminal:
  emitted speech is never replayed on a fallback worker.

  Use as an adapter with `:router`, `:route` (a key or an input-to-key function),
  and optional `:timeout_ms` (30,000 for the entire request). `put_route/3`
  replaces a route for subsequent requests without changing active requests.
  An empty target list disables the route. Targets can be local or remote
  `AudioFlow.Worker` processes. Configure engines and shared models on those
  workers, not in individual sessions.
  """
  use GenServer
  @behaviour AudioFlow.Adapter

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def put_route(router, key, workers) when is_list(workers),
    do: GenServer.call(router, {:put, key, workers})

  @impl AudioFlow.Adapter
  def run(input, options, emit) do
    router = Keyword.fetch!(options, :router)
    route = Keyword.fetch!(options, :route)
    key = if is_function(route, 1), do: route.(input), else: route
    timeout = Keyword.get(options, :timeout_ms, 30_000)

    if not (is_integer(timeout) and timeout > 0),
      do: raise(ArgumentError, "timeout_ms must be positive")

    deadline = now() + timeout

    case select(router, key, timeout) do
      {:ok, workers} -> dispatch(workers, key, input, emit, deadline, [])
      error -> error
    end
  end

  @impl GenServer
  def init(options) do
    routes = Map.new(Keyword.get(options, :routes, %{}))

    if not Enum.all?(routes, fn {_, workers} -> is_list(workers) end),
      do: raise(ArgumentError, "each route must contain a list of workers")

    {:ok, routes}
  end

  @impl GenServer
  def handle_call({:put, key, workers}, _from, routes),
    do: {:reply, :ok, Map.put(routes, key, workers)}

  def handle_call({:select, key}, _from, routes) do
    case Map.fetch(routes, key) do
      {:ok, [first | rest] = workers} ->
        {:reply, {:ok, workers}, Map.put(routes, key, rest ++ [first])}

      {:ok, []} ->
        {:reply, {:error, {:no_worker_available, key, []}}, routes}

      :error ->
        {:reply, {:error, {:unknown_route, key}}, routes}
    end
  end

  defp select(router, key, timeout) do
    GenServer.call(router, {:select, key}, timeout)
  catch
    :exit, reason -> {:error, {:router_unavailable, reason}}
  end

  defp dispatch([], key, _input, _emit, _deadline, errors),
    do: {:error, {:no_worker_available, key, Enum.reverse(errors)}}

  defp dispatch([worker | rest], key, input, emit, deadline, errors) do
    remaining = deadline - now()

    if remaining <= 0 do
      {:error, :worker_timeout}
    else
      case AudioFlow.Worker.run(input, [worker: worker, timeout_ms: remaining], emit) do
        {:error, {kind, _} = reason} when kind in [:worker_rejected, :worker_unavailable] ->
          dispatch(rest, key, input, emit, deadline, [{worker, reason} | errors])

        result ->
          result
      end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
