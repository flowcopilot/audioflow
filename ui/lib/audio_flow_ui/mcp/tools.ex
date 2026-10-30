# Tools of AudioFlowUI.MCP. They are in their own file because the server compiles their specs.

defmodule AudioFlowUI.MCP.ListNodeTypes do
  use Sake.Tool,
    name: "list_node_types",
    description:
      "Lists the node types that a graph can use, with their input and output ports and their options. " <>
        "An edge connects an output port to an input port of the same kind (audio, image, or text).",
    annotations: [read_only: true, idempotent: true]

  @impl true
  def execute(_args, _ctx), do: {:ok, %{"node_types" => AudioFlowUI.node_types()}}
end

defmodule AudioFlowUI.MCP.ListGraphs do
  use Sake.Tool,
    name: "list_graphs",
    description: "Lists the saved agent graphs with their validation errors.",
    annotations: [read_only: true, idempotent: true]

  @impl true
  def execute(_args, _ctx) do
    graphs =
      for graph <- AudioFlowUI.Graphs.list() do
        %{"id" => graph["id"], "name" => graph["name"], "errors" => AudioFlowUI.errors(graph)}
      end

    {:ok, %{"graphs" => graphs}}
  end
end

defmodule AudioFlowUI.MCP.GetGraph do
  use Sake.Tool,
    name: "get_graph",
    description: "Returns one saved graph and its validation errors.",
    annotations: [read_only: true, idempotent: true]

  arg :id, :string, required: true, description: "The graph id."

  @impl true
  def execute(%{id: id}, _ctx) do
    with {:ok, graph} <- AudioFlowUI.MCP.fetch(id), do: {:ok, AudioFlowUI.MCP.graph_result(graph)}
  end
end

defmodule AudioFlowUI.MCP.SaveGraph do
  use Sake.Tool,
    name: "save_graph",
    description: """
    Creates a graph, or replaces the saved graph with the same id. An incomplete graph is saved \
    and its validation errors are returned, so you can build it in steps. The graph is an object: \
    "id" (lowercase letters, digits, "_" and "-"), "name", "nodes" (each with "id", "type", \
    optional "options" and "position" {"x", "y"}), "edges" (each with "from" and "to" node ids), \
    and "settings" ("history", "timeout_ms", "max_events"). A graph runs as one session: \
    input -> STT or vision -> LLM -> TTS. Call list_node_types for the types.\
    """,
    annotations: [idempotent: true]

  arg :graph, :any, required: true, description: "The complete graph object."

  @impl true
  def execute(%{graph: graph}, _ctx) do
    case AudioFlowUI.Graphs.put(graph) do
      {:ok, graph} -> {:ok, AudioFlowUI.MCP.graph_result(graph)}
      {:error, error} -> {:error, AudioFlowUI.MCP.message(error)}
    end
  end
end

defmodule AudioFlowUI.MCP.ValidateGraph do
  use Sake.Tool,
    name: "validate_graph",
    description:
      "Validates a graph object without saving it. Returns its errors, or an empty list.",
    annotations: [read_only: true, idempotent: true]

  arg :graph, :any, required: true, description: "The graph object, as for save_graph."

  @impl true
  def execute(%{graph: graph}, _ctx), do: {:ok, %{"errors" => AudioFlowUI.errors(graph)}}
end

defmodule AudioFlowUI.MCP.DeleteGraph do
  use Sake.Tool,
    name: "delete_graph",
    description: "Deletes a saved graph.",
    annotations: [destructive: true, idempotent: true]

  arg :id, :string, required: true, description: "The graph id."

  @impl true
  def execute(%{id: id}, _ctx) do
    case AudioFlowUI.Graphs.delete(id) do
      :ok -> {:ok, "Deleted graph #{inspect(id)}."}
      {:error, :not_found} -> {:error, "no graph with id #{inspect(id)}"}
    end
  end
end

defmodule AudioFlowUI.MCP.RunGraph do
  use Sake.Tool,
    name: "run_graph",
    description: """
    Runs one text turn of a saved, valid graph and returns the reply, the events of each stage, \
    and timing metrics in microseconds. The graph needs a text input node. Audio events give \
    the PCM size only.\
    """,
    annotations: [open_world: true]

  arg :id, :string, required: true, description: "The graph id."
  arg :text, :string, required: true, min_length: 1, description: "The user message."

  @impl true
  def execute(%{id: id, text: text}, _ctx) do
    with {:ok, graph} <- AudioFlowUI.MCP.fetch(id) do
      case AudioFlowUI.Runs.run_text(graph, text) do
        {:ok, result} -> {:ok, result}
        {:error, error} -> {:error, AudioFlowUI.MCP.message(error)}
      end
    end
  end
end
