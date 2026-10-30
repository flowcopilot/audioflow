defmodule AudioFlowUI.MCP do
  @moduledoc """
  The MCP server for coding agents. It has the same graph operations as the
  dashboard: list node types, read, save, validate, delete, and run graphs.
  """
  use Sake.Server, name: "audioflow", version: "0.1.0"

  alias AudioFlowUI.MCP

  tools [
    MCP.ListNodeTypes,
    MCP.ListGraphs,
    MCP.GetGraph,
    MCP.SaveGraph,
    MCP.ValidateGraph,
    MCP.DeleteGraph,
    MCP.RunGraph
  ]

  @doc false
  def graph_result(graph), do: %{"graph" => graph, "errors" => AudioFlowUI.errors(graph)}

  @doc false
  def fetch(id) do
    case AudioFlowUI.Graphs.get(id) do
      {:ok, graph} -> {:ok, graph}
      {:error, :not_found} -> {:error, "no graph with id #{inspect(id)}"}
    end
  end

  @doc false
  def message(errors) when is_list(errors), do: Enum.join(errors, "\n")
  def message(error) when is_binary(error), do: error
  def message(error), do: inspect(error)
end
