defmodule AudioFlowUI.Graphs do
  @moduledoc """
  Saved graphs, one JSON file each in the data directory.

  A graph can be saved while it is incomplete, so an editor or an agent can
  build it in steps. Only a valid graph runs. The id must match
  `#{inspect(~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/.source)}`, so it is safe as a
  file name. Each change broadcasts `{:graph_saved, graph}` or
  `{:graph_deleted, id}` on `topic/0`.
  """
  use GenServer
  alias AudioFlow.Graph

  @id ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @topic "graphs"

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(AudioFlowUI.PubSub, @topic)

  @doc "All graphs, sorted by id."
  def list, do: GenServer.call(__MODULE__, :list)

  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc "Creates or replaces the graph with the same id."
  def put(graph) when is_map(graph) do
    graph = Graph.normalize(graph)

    with :ok <- check_shape(graph) do
      graph =
        graph
        |> Map.put_new("name", graph["id"])
        |> Map.put_new("nodes", [])
        |> Map.put_new("edges", [])

      GenServer.call(__MODULE__, {:put, graph})
    end
  end

  def put(_), do: {:error, "graph must be a map"}

  def delete(id), do: GenServer.call(__MODULE__, {:delete, id})

  defp check_shape(graph) do
    cond do
      not (is_binary(graph["id"]) and Regex.match?(@id, graph["id"])) ->
        {:error, "graph id must match #{@id.source}"}

      not is_list(Map.get(graph, "nodes", [])) ->
        {:error, "nodes must be a list"}

      not is_list(Map.get(graph, "edges", [])) ->
        {:error, "edges must be a list"}

      true ->
        :ok
    end
  end

  @impl true
  def init(_options) do
    dir = data_dir()
    new? = not File.dir?(dir)
    File.mkdir_p!(dir)

    graphs =
      for file <- Path.wildcard(Path.join(dir, "*.json")),
          {:ok, %{"id" => id} = graph} <- [file |> File.read!() |> Jason.decode()],
          Path.basename(file, ".json") == id,
          into: %{},
          do: {id, graph}

    state = %{dir: dir, graphs: graphs}

    state =
      if new? and Application.get_env(:audio_flow_ui, :seed, true),
        do: elem(save(state, demo()), 1),
        else: state

    {:ok, state}
  end

  @impl true
  def handle_call(:list, _from, state),
    do: {:reply, state.graphs |> Map.values() |> Enum.sort_by(& &1["id"]), state}

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state.graphs, id) do
      {:ok, graph} -> {:reply, {:ok, graph}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:put, graph}, _from, state) do
    {graph, state} = save(state, graph)
    Phoenix.PubSub.broadcast(AudioFlowUI.PubSub, @topic, {:graph_saved, graph})
    {:reply, {:ok, graph}, state}
  end

  def handle_call({:delete, id}, _from, state) do
    if Map.has_key?(state.graphs, id) do
      File.rm!(path(state, id))
      Phoenix.PubSub.broadcast(AudioFlowUI.PubSub, @topic, {:graph_deleted, id})
      {:reply, :ok, %{state | graphs: Map.delete(state.graphs, id)}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  # A temporary file and a rename keep the saved file complete after a crash.
  defp save(state, graph) do
    path = path(state, graph["id"])
    temporary = path <> ".tmp"
    File.write!(temporary, Jason.encode_to_iodata!(graph, pretty: true))
    File.rename!(temporary, path)
    {graph, put_in(state.graphs[graph["id"]], graph)}
  end

  defp path(state, id), do: Path.join(state.dir, id <> ".json")

  defp data_dir,
    do:
      Application.get_env(:audio_flow_ui, :data_dir) ||
        :filename.basedir(:user_data, "audioflow_ui")

  defp demo do
    %{
      "id" => "demo",
      "name" => "Demo voice agent",
      "nodes" => [
        %{"id" => "mic", "type" => "input.audio", "position" => %{"x" => 0, "y" => 0}},
        %{"id" => "keys", "type" => "input.text", "position" => %{"x" => 0, "y" => 200}},
        %{"id" => "stt", "type" => "demo.stt", "position" => %{"x" => 320, "y" => 0}},
        %{"id" => "llm", "type" => "demo.llm", "position" => %{"x" => 640, "y" => 100}},
        %{"id" => "tts", "type" => "demo.tts", "position" => %{"x" => 960, "y" => 100}}
      ],
      "edges" => [
        %{"from" => "mic", "to" => "stt"},
        %{"from" => "keys", "to" => "llm"},
        %{"from" => "stt", "to" => "llm"},
        %{"from" => "llm", "to" => "tts"}
      ]
    }
  end
end
