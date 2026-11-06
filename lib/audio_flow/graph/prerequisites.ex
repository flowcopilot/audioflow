defmodule AudioFlow.Graph.Prerequisites do
  @moduledoc "Checks node configuration through the catalog; does not verify external connectivity."
  alias AudioFlow.Graph

  def errors(graph, catalog) do
    for node <- Graph.normalize(graph)["nodes"] || [],
        is_map(node),
        message <- node_errors(node, catalog),
        do: "#{node["id"]}: #{message}"
  end

  defp node_errors(node, catalog) do
    case Map.fetch(catalog, node["type"]) do
      {:ok, {module, _spec}} ->
        if function_exported?(module, :prerequisites, 2),
          do: module.prerequisites(node["type"], node["options"] || %{}),
          else: []

      :error ->
        []
    end
  end
end
