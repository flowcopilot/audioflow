defmodule AudioFlow.Servings do
  @moduledoc """
  Shared `Nx.Serving` processes that load on first use.

  Graph model nodes name a model; `fetch/2` loads it once and returns the
  serving name for all sessions. Add this module to the inference children:

      config :audio_flow, :inference_children, [AudioFlow.Servings]

  `build` is a function of no arguments that returns an `Nx.Serving`, or
  `{:ok, serving}` or `{:error, reason}`. One load runs for each key, and
  other callers of the same key wait for it. The load runs in a task of the
  registry, so a cancelled or timed-out turn does not stop a download. A
  failed load is not kept, so the next call tries again. A loaded serving
  stays until `release/1`.
  """
  use Supervisor

  @loader AudioFlow.Servings.Loader

  def start_link(options \\ []), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    Supervisor.init(
      [
        {DynamicSupervisor, name: AudioFlow.Servings.Supervisor, strategy: :one_for_one},
        @loader
      ],
      strategy: :rest_for_one
    )
  end

  @doc "Returns `{:ok, serving_name}` or `{:error, reason}`. Waits for the load."
  def fetch(key, build) when is_function(build, 0),
    do: GenServer.call(@loader, {:fetch, key, build}, :infinity)

  @doc "The keys of loaded servings."
  def loaded, do: GenServer.call(@loader, :loaded)

  @doc "Stops a loaded serving. Its key loads again on the next fetch."
  def release(key), do: GenServer.call(@loader, {:release, key})
end

defmodule AudioFlow.Servings.Loader do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil), do: {:ok, %{loaded: %{}, loading: %{}, count: 0}}

  @impl true
  def handle_call({:fetch, key, build}, from, state) do
    case state do
      %{loaded: %{^key => %{name: name}}} ->
        {:reply, {:ok, name}, state}

      %{loading: %{^key => load}} ->
        {:noreply, put_in(state.loading[key], %{load | waiters: [from | load.waiters]})}

      _ ->
        # Atom names: Nx.Serving needs them, and there is one per distinct model.
        name = Module.concat(AudioFlow.Servings, "Serving#{state.count}")
        task = Task.Supervisor.async_nolink(AudioFlow.Tasks, fn -> load(name, build) end)
        load = %{ref: task.ref, name: name, waiters: [from]}
        {:noreply, %{state | loading: Map.put(state.loading, key, load), count: state.count + 1}}
    end
  end

  def handle_call(:loaded, _from, state), do: {:reply, Map.keys(state.loaded), state}

  def handle_call({:release, key}, _from, state) do
    case Map.pop(state.loaded, key) do
      {nil, _} ->
        {:reply, {:error, :not_loaded}, state}

      {%{pid: pid}, loaded} ->
        DynamicSupervisor.terminate_child(AudioFlow.Servings.Supervisor, pid)
        {:reply, :ok, %{state | loaded: loaded}}
    end
  end

  @impl true
  def handle_info({ref, result}, state) do
    case Enum.find(state.loading, fn {_, load} -> load.ref == ref end) do
      {key, load} ->
        Process.demonitor(ref, [:flush])
        state = %{state | loading: Map.delete(state.loading, key)}

        case result do
          {:ok, pid} ->
            reply(load, {:ok, load.name})
            {:noreply, put_in(state.loaded[key], %{name: load.name, pid: pid})}

          {:error, _} = error ->
            reply(load, error)
            {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    case Enum.find(state.loading, fn {_, load} -> load.ref == ref end) do
      {key, load} ->
        reply(load, {:error, {:load_exit, reason}})
        {:noreply, %{state | loading: Map.delete(state.loading, key)}}

      nil ->
        {:noreply, state}
    end
  end

  defp reply(load, result), do: Enum.each(load.waiters, &GenServer.reply(&1, result))

  defp load(name, build) do
    serving =
      case build.() do
        %Nx.Serving{} = serving -> {:ok, serving}
        {:ok, %Nx.Serving{}} = ok -> ok
        {:error, _} = error -> error
        other -> {:error, {:invalid_serving, other}}
      end

    with {:ok, serving} <- serving do
      DynamicSupervisor.start_child(
        AudioFlow.Servings.Supervisor,
        AudioFlow.Models.child_spec(name, serving)
      )
    end
  end
end
