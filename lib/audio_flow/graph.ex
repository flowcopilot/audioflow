defmodule AudioFlow.Graph do
  @moduledoc """
  An agent described as data: typed nodes and the edges between them.

  A graph is a JSON-compatible map:

      %{
        "nodes" => [
          %{"id" => "mic", "type" => "input.audio"},
          %{"id" => "stt", "type" => "demo.stt"},
          %{"id" => "llm", "type" => "llm.chat_http",
            "options" => %{"endpoint" => "http://localhost:8080/v1/chat/completions",
                           "model" => "qwen3"}},
          %{"id" => "tts", "type" => "demo.tts"}
        ],
        "edges" => [
          %{"from" => "mic", "to" => "stt"},
          %{"from" => "stt", "to" => "llm"},
          %{"from" => "llm", "to" => "tts"}
        ],
        "settings" => %{"history" => true}
      }

  Atom keys are also accepted. Other keys, such as a node `"position"` or a
  graph `"name"`, belong to the caller and are ignored. Node types come from a
  catalog of `AudioFlow.Graph.Node` modules. An edge connects the output port
  of one node to the input port of another, and both ports must carry the
  same kind of value.

  A valid graph has at least one input node and no cycles, and each other
  node has a path from an input node. A node can have several inputs and
  several outputs. With the `"history"` setting, exactly one node must accept
  conversation history. Settings are `"history"` (boolean), `"timeout_ms"`,
  and `"max_events"`. Validation reports all errors that it finds.
  `session_options/2` compiles a valid graph for `AudioFlow.Graph.Runner`.
  """
  alias AudioFlow.Graph.Nodes
  alias AudioFlow.Graph.OptionSchema

  @default_nodes [Nodes.Input, Nodes.Audio, Nodes.Demo, Nodes.ChatHTTP, Nodes.RAG]
  @kinds [:audio, :image, :text, :vector]
  @events [:transcript, :description, :text, :audio, :image, :vector]
  @settings %{
    "history" => %{name: :history, type: :boolean},
    "timeout_ms" => %{name: :timeout_ms, type: :positive},
    "max_events" => %{name: :max_events, type: :positive}
  }

  @doc "Builds a catalog from node modules. The default has input, audio, demo, and HTTP LLM nodes."
  def catalog(modules \\ @default_nodes) do
    Enum.reduce(modules, %{}, fn module, catalog ->
      Enum.reduce(module.nodes(), catalog, &add_type(&2, module, &1))
    end)
  end

  defp add_type(catalog, _module, spec) when is_map_key(catalog, spec.type),
    do: raise(ArgumentError, "duplicate node type #{inspect(spec.type)}")

  defp add_type(catalog, module, spec),
    do: Map.put(catalog, spec.type, {module, complete_spec(spec)})

  defp complete_spec(spec) do
    spec =
      Map.merge(
        %{input_mode: :join, event: spec.output, history: false},
        spec
      )

    case spec_error(spec) do
      nil -> spec
      message -> raise ArgumentError, "node type #{spec.type}: #{message}"
    end
  end

  defp spec_error(spec), do: port_error(spec) || mode_error(spec)

  defp port_error(spec) do
    cond do
      not (valid_port?(spec.input) and valid_port?(spec.output)) ->
        "ports must be nil or one of #{inspect(@kinds)}"

      spec.output != nil and spec.event not in @events ->
        "event must be one of #{inspect(@events)}"

      true ->
        nil
    end
  end

  defp mode_error(spec) do
    cond do
      spec.input_mode not in [:join, :stream] ->
        "input_mode must be :join or :stream"

      spec.history and not (spec.input == :text and spec.input_mode == :join) ->
        "a history node needs a joined text input"

      true ->
        nil
    end
  end

  defp valid_port?(port), do: port in [nil | @kinds]

  @doc "The node type specs of a catalog, sorted by type."
  def node_types(catalog),
    do: catalog |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.type)

  @doc "Returns `:ok` or `{:error, messages}`."
  def validate(graph, catalog) do
    case check(graph, catalog) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Returns options for `AudioFlow.start_session/1`, without `:owner`."
  def session_options(graph, catalog) do
    with {:ok, %{nodes: nodes, edges: edges, settings: settings}} <- check(graph, catalog) do
      {:ok, [graph: plan(nodes, edges, settings)] ++ settings}
    end
  end

  defp plan(nodes, edges, settings) do
    history? = Keyword.get(settings, :history, false)

    steps =
      Map.new(nodes, fn {id, node} ->
        step = %{
          id: id,
          type: node.type,
          adapter: if(node.spec.input, do: node.module.adapter(node.type, node.options)),
          input_mode: node.spec.input_mode,
          event: node.spec.event,
          history: history? and node.spec.history,
          sources: for({from, ^id} <- edges, do: from),
          targets: for({^id, to} <- edges, do: to)
        }

        {id, step}
      end)

    inputs =
      nodes
      |> Enum.filter(fn {_, node} -> node.spec.input == nil end)
      |> Enum.group_by(fn {_, node} -> node.spec.output end, fn {id, _} -> id end)
      |> Map.new(fn {kind, ids} -> {kind, Enum.sort(ids)} end)

    %AudioFlow.Graph.Plan{steps: steps, inputs: inputs}
  end

  @doc "Converts map keys to strings at every level."
  def normalize(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), normalize(value)} end)

  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  def normalize(value), do: value

  defp check(%{} = graph, catalog) when not is_struct(graph) do
    graph = normalize(graph)

    with {:ok, nodes, edges, settings} <- shape(graph) do
      declared = for %{"id" => id} <- nodes, is_binary(id), into: MapSet.new(), do: id
      {nodes, node_errors} = resolve_nodes(nodes, catalog)
      {edges, edge_errors} = resolve_edges(edges, nodes, declared)
      {settings, setting_errors} = resolve_settings(settings)

      checked(nodes, edges, settings, node_errors ++ edge_errors ++ setting_errors)
    end
  end

  defp check(_, _), do: {:error, ["graph must be a map"]}

  defp checked(nodes, edges, settings, []) do
    with :ok <- topology(nodes, edges, settings),
         do: {:ok, %{nodes: nodes, edges: edges, settings: settings}}
  end

  defp checked(_nodes, _edges, _settings, errors), do: {:error, errors}

  defp shape(graph) do
    nodes = Map.get(graph, "nodes")
    edges = Map.get(graph, "edges") || []
    settings = Map.get(graph, "settings") || %{}

    errors =
      [
        {is_list(nodes), "nodes must be a list"},
        {is_list(edges), "edges must be a list"},
        {is_map(settings), "settings must be a map"}
      ]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    if errors == [], do: {:ok, nodes, edges, settings}, else: {:error, errors}
  end

  defp resolve_nodes(nodes, catalog) do
    {resolved, errors} =
      Enum.reduce(nodes, {%{}, []}, fn node, {resolved, errors} ->
        case resolve_node(node, catalog) do
          {:ok, %{id: id}} when is_map_key(resolved, id) ->
            {resolved, ["duplicate node id #{inspect(id)}" | errors]}

          {:ok, node} ->
            {Map.put(resolved, node.id, node), errors}

          {:error, node_errors} ->
            {resolved, Enum.reverse(node_errors, errors)}
        end
      end)

    {resolved, Enum.reverse(errors)}
  end

  defp resolve_node(%{"id" => id, "type" => type} = node, catalog)
       when is_binary(id) and id != "" and is_binary(type) do
    with {:ok, {module, spec}} <- fetch_type(catalog, id, type),
         {:ok, options} <- resolve_options(id, spec.options, Map.get(node, "options") || %{}) do
      {:ok, %{id: id, type: type, module: module, spec: spec, options: options}}
    end
  end

  defp resolve_node(node, _),
    do: {:error, ["each node needs a string id and type, got #{inspect(node)}"]}

  defp fetch_type(catalog, id, type) do
    case Map.fetch(catalog, type) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, ["node #{inspect(id)}: unknown type #{inspect(type)}"]}
    end
  end

  defp resolve_options(id, _specs, given) when not is_map(given),
    do: {:error, ["node #{inspect(id)}: options must be a map"]}

  defp resolve_options(id, specs, given) do
    {options, errors} = OptionSchema.resolve(specs, given)

    errors =
      Enum.map(errors, fn
        {:unknown, key} ->
          "node #{inspect(id)}: unknown option #{inspect(key)}"

        {name, :required} ->
          "node #{inspect(id)}: option #{name} is required"

        {name, {:invalid, type}} ->
          "node #{inspect(id)}: option #{name} must be #{OptionSchema.type_name(type)}"
      end)

    if errors == [], do: {:ok, options}, else: {:error, errors}
  end

  defp resolve_edges(edges, nodes, declared) do
    {resolved, errors} =
      Enum.reduce(edges, {[], []}, fn edge, {resolved, errors} ->
        case resolve_edge(edge, nodes, declared) do
          {:ok, pair} ->
            add_edge(pair, resolved, errors)

          :skip ->
            {resolved, errors}

          {:error, error} ->
            {resolved, [error | errors]}
        end
      end)

    {Enum.reverse(resolved), Enum.reverse(errors)}
  end

  defp add_edge(pair, resolved, errors) do
    if pair in resolved,
      do: {resolved, ["duplicate edge #{edge_name(pair)}" | errors]},
      else: {[pair | resolved], errors}
  end

  defp resolve_edge(%{"from" => from, "to" => to}, nodes, declared)
       when is_binary(from) and is_binary(to) do
    with {:ok, source} <- fetch_node(nodes, declared, from),
         {:ok, target} <- fetch_node(nodes, declared, to) do
      cond do
        source.spec.output == nil ->
          {:error, "edge #{edge_name({from, to})}: #{inspect(from)} has no output"}

        target.spec.input == nil ->
          {:error, "edge #{edge_name({from, to})}: #{inspect(to)} has no input"}

        source.spec.output != target.spec.input ->
          {:error,
           "edge #{edge_name({from, to})}: #{source.spec.output} output cannot connect to #{target.spec.input} input"}

        true ->
          {:ok, {from, to}}
      end
    end
  end

  defp resolve_edge(edge, _, _),
    do: {:error, "each edge needs string from and to node ids, got #{inspect(edge)}"}

  defp fetch_node(nodes, declared, id) do
    cond do
      Map.has_key?(nodes, id) -> {:ok, nodes[id]}
      MapSet.member?(declared, id) -> :skip
      true -> {:error, "edge refers to unknown node #{inspect(id)}"}
    end
  end

  defp edge_name({from, to}), do: "#{inspect(from)} -> #{inspect(to)}"

  defp resolve_settings(settings) do
    Enum.reduce(settings, {[], []}, fn {key, value}, {resolved, errors} ->
      case resolve_setting(key, value) do
        {:ok, options} -> {resolved ++ options, errors}
        {:error, error} -> {resolved, errors ++ [error]}
      end
    end)
  end

  defp resolve_setting(key, value) do
    case Map.fetch(@settings, key) do
      :error ->
        {:error, "unknown setting #{inspect(key)}"}

      {:ok, spec} ->
        case OptionSchema.resolve([spec], %{key => value}) do
          {options, []} -> {:ok, Map.to_list(options)}
          {_, _} -> {:error, "setting #{key} must be #{OptionSchema.type_name(spec.type)}"}
        end
    end
  end

  defp topology(nodes, edges, settings) do
    inputs = for {id, %{spec: %{input: nil}}} <- nodes, do: id
    targets = Enum.group_by(edges, &elem(&1, 0), &elem(&1, 1))
    reached = reach(inputs, targets, MapSet.new())

    unreached =
      for {id, _} <- Enum.sort(nodes),
          not MapSet.member?(reached, id),
          do: "node #{inspect(id)} has no path from an input node"

    history =
      for {id, node} <- Enum.sort(nodes), node.spec.history, do: id

    errors =
      if(inputs == [], do: ["a graph needs an input node"], else: []) ++
        cycles(Map.keys(nodes), targets) ++
        unreached ++
        history_errors(Keyword.get(settings, :history, false), history)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp reach([], _targets, reached), do: reached

  defp reach([id | rest], targets, reached) do
    if MapSet.member?(reached, id),
      do: reach(rest, targets, reached),
      else: reach(Map.get(targets, id, []) ++ rest, targets, MapSet.put(reached, id))
  end

  defp cycles(ids, targets) do
    {_, errors} =
      Enum.reduce(Enum.sort(ids), {MapSet.new(), []}, fn id, {done, errors} ->
        visit(id, [], targets, done, errors)
      end)

    errors |> Enum.reverse() |> Enum.uniq()
  end

  defp visit(id, path, targets, done, errors) do
    cond do
      id in path ->
        cycle = [id] ++ Enum.reverse(Enum.take_while(path, &(&1 != id))) ++ [id]
        {done, ["edges form a cycle: #{Enum.map_join(cycle, " -> ", &inspect/1)}" | errors]}

      MapSet.member?(done, id) ->
        {done, errors}

      true ->
        {done, errors} =
          Enum.reduce(Map.get(targets, id, []), {done, errors}, fn target, {done, errors} ->
            visit(target, [id | path], targets, done, errors)
          end)

        {MapSet.put(done, id), errors}
    end
  end

  defp history_errors(false, _), do: []
  defp history_errors(true, [_]), do: []

  defp history_errors(true, []),
    do: ["the history setting needs a node that accepts history, such as an LLM node"]

  defp history_errors(true, ids),
    do: [
      "the history setting allows only one node that accepts history, found #{Enum.map_join(ids, ", ", &inspect/1)}"
    ]
end
