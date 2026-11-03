defmodule AudioFlowUI.Prerequisites do
  @moduledoc "Configuration checks, not claims of provider or database connectivity."
  alias AudioFlow.Graph.Nodes.Providers

  def errors(graph) do
    for node <- AudioFlow.Graph.normalize(graph)["nodes"] || [],
        message <- node_errors(node),
        do: "#{node["id"]}: #{message}"
  end

  defp node_errors(%{"type" => type} = node) do
    case Providers.providers()[type] do
      {_, env} ->
        if System.get_env(env) in [nil, ""],
          do: ["set #{env} in the server environment"],
          else: []

      nil ->
        profile = get_in(node, ["options", "profile"])

        if type == "rag.retrieve" and
             not Map.has_key?(Application.get_env(:audio_flow, :retrieval_profiles, %{}), profile),
           do: ["retrieval profile is not configured on the server (database/backend required)"],
           else: []
    end
  end

  defp node_errors(_), do: []
end
