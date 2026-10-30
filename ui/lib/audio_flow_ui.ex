defmodule AudioFlowUI do
  @moduledoc """
  A dashboard for AudioFlow agent graphs.

  The browser and the MCP endpoint use the same functions: `AudioFlowUI.Graphs`
  stores graphs, and `AudioFlowUI.Runs` runs them. A change from either side
  reaches open dashboards through PubSub.

  Node types come from `config :audio_flow_ui, :nodes`, a list of
  `AudioFlow.Graph.Node` modules. The default has the input, audio, demo, and
  HTTP LLM nodes of the core library. A build with `AUDIOFLOW_ML=1` also has
  the native model nodes of `AudioFlow.Graph.Nodes.Models`.
  """
  alias AudioFlow.Graph

  @core_nodes [Graph.Nodes.Input, Graph.Nodes.Audio, Graph.Nodes.Demo, Graph.Nodes.ChatHTTP]

  def catalog, do: Graph.catalog(Application.get_env(:audio_flow_ui, :nodes, default_nodes()))

  defp default_nodes do
    if Code.ensure_loaded?(Graph.Nodes.Models),
      do: @core_nodes ++ [Graph.Nodes.Models],
      else: @core_nodes
  end

  @doc "Node type specs as JSON-compatible maps."
  def node_types, do: Enum.map(Graph.node_types(catalog()), &json_spec/1)

  @doc "Returns `[]` for a valid graph, or its validation messages."
  def errors(graph) do
    case Graph.validate(graph, catalog()) do
      :ok -> []
      {:error, errors} -> errors
    end
  end

  defp json_spec(spec) do
    %{
      "type" => spec.type,
      "title" => spec.title,
      "description" => spec.description,
      "input" => spec.input && Atom.to_string(spec.input),
      "output" => spec.output && Atom.to_string(spec.output),
      "input_mode" => Atom.to_string(spec.input_mode),
      "event" => spec.event && Atom.to_string(spec.event),
      "history" => spec.history,
      "options" => Enum.map(spec.options, &json_option/1)
    }
  end

  defp json_option(option) do
    type =
      case option.type do
        {:enum, values} -> %{"type" => "enum", "values" => values}
        type -> %{"type" => Atom.to_string(type)}
      end

    option
    |> Map.take([:required, :default, :description])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(type)
    |> Map.put("name", Atom.to_string(option.name))
  end
end
