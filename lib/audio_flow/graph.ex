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

  A graph runs as one `AudioFlow.Session`, so it must have the session shape:
  audio input to one STT node, image input to one vision node, or both; the
  STT, vision, and optional text input nodes feed one LLM node; the LLM node
  feeds one TTS node. Settings are `"history"` (boolean), `"timeout_ms"`, and
  `"max_events"`. Validation reports all errors that it finds.
  """
  alias AudioFlow.Graph.Nodes

  @default_nodes [Nodes.Input, Nodes.Demo, Nodes.ChatHTTP]
  @edges [
    {{:input, :audio}, :stt},
    {{:input, :image}, :vision},
    {{:input, :text}, :llm},
    {:stt, :llm},
    {:vision, :llm},
    {:llm, :tts}
  ]
  @settings %{"history" => :boolean, "timeout_ms" => :positive, "max_events" => :positive}

  @doc "Builds a catalog from node modules. The default has input, demo, and HTTP LLM nodes."
  def catalog(modules \\ @default_nodes) do
    Enum.reduce(modules, %{}, fn module, catalog ->
      Enum.reduce(module.nodes(), catalog, fn spec, catalog ->
        if Map.has_key?(catalog, spec.type),
          do: raise(ArgumentError, "duplicate node type #{inspect(spec.type)}")

        Map.put(catalog, spec.type, {module, spec})
      end)
    end)
  end

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
    with {:ok, %{roles: roles, settings: settings}} <- check(graph, catalog) do
      adapters =
        for role <- [:stt, :vision, :llm, :tts], Map.has_key?(roles, role) do
          node = roles[role]
          {role, node.module.adapter(node.type, node.options)}
        end

      {:ok, adapters ++ settings}
    end
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

      case node_errors ++ edge_errors ++ setting_errors do
        [] ->
          with {:ok, roles} <- topology(nodes, edges),
               do: {:ok, %{roles: roles, settings: settings}}

        errors ->
          {:error, errors}
      end
    end
  end

  defp check(_, _), do: {:error, ["graph must be a map"]}

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
    names = Enum.map(specs, &Atom.to_string(&1.name))

    unknown =
      for key <- Map.keys(given),
          key not in names,
          do: "node #{inspect(id)}: unknown option #{inspect(key)}"

    {options, errors} =
      Enum.reduce(specs, {%{}, unknown}, fn spec, {options, errors} ->
        case Map.get(given, Atom.to_string(spec.name)) do
          nil when is_map_key(spec, :default) ->
            {Map.put(options, spec.name, spec.default), errors}

          nil ->
            if spec[:required],
              do: {options, errors ++ ["node #{inspect(id)}: option #{spec.name} is required"]},
              else: {options, errors}

          value ->
            if type?(spec.type, value),
              do: {Map.put(options, spec.name, value), errors},
              else:
                {options,
                 errors ++
                   ["node #{inspect(id)}: option #{spec.name} must be #{type_name(spec.type)}"]}
        end
      end)

    if errors == [], do: {:ok, options}, else: {:error, errors}
  end

  defp type?(:string, value), do: is_binary(value)
  defp type?(:integer, value), do: is_integer(value)
  defp type?(:boolean, value), do: is_boolean(value)
  defp type?({:enum, values}, value), do: value in values

  defp type_name({:enum, values}), do: "one of #{Enum.map_join(values, ", ", &inspect/1)}"
  defp type_name(type), do: "a #{type}"

  defp resolve_edges(edges, nodes, declared) do
    {resolved, errors} =
      Enum.reduce(edges, {[], []}, fn edge, {resolved, errors} ->
        case resolve_edge(edge, nodes, declared) do
          {:ok, pair} ->
            if pair in resolved,
              do: {resolved, ["duplicate edge #{edge_name(pair)}" | errors]},
              else: {[pair | resolved], errors}

          :skip ->
            {resolved, errors}

          {:error, error} ->
            {resolved, [error | errors]}
        end
      end)

    {Enum.reverse(resolved), Enum.reverse(errors)}
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
      # An invalid node is reported once, as a node error.
      MapSet.member?(declared, id) -> :skip
      true -> {:error, "edge refers to unknown node #{inspect(id)}"}
    end
  end

  defp edge_name({from, to}), do: "#{inspect(from)} -> #{inspect(to)}"

  defp resolve_settings(settings) do
    Enum.reduce(settings, {[], []}, fn {key, value}, {resolved, errors} ->
      case {Map.fetch(@settings, key), value} do
        {:error, _} ->
          {resolved, errors ++ ["unknown setting #{inspect(key)}"]}

        {{:ok, _}, nil} ->
          {resolved, errors}

        {{:ok, :boolean}, value} when is_boolean(value) ->
          {resolved ++ [setting(key, value)], errors}

        {{:ok, :positive}, value} when is_integer(value) and value > 0 ->
          {resolved ++ [setting(key, value)], errors}

        {{:ok, :boolean}, _} ->
          {resolved, errors ++ ["setting #{key} must be a boolean"]}

        {{:ok, :positive}, _} ->
          {resolved, errors ++ ["setting #{key} must be a positive integer"]}
      end
    end)
  end

  defp setting(key, value), do: {String.to_existing_atom(key), value}

  defp topology(nodes, edges) do
    nodes = Map.values(nodes) |> Enum.sort_by(& &1.id)
    by_role = Enum.group_by(nodes, &role(&1.spec))

    count_errors =
      for {role, max} <- [{:stt, 1}, {:vision, 1}, {:llm, 1}, {:tts, 1}] ++ inputs(1),
          length(Map.get(by_role, role, [])) > max,
          do: "a graph can have only one node of role #{role_name(role)}"

    required_errors =
      [
        {Map.has_key?(by_role, :llm), "a graph needs an LLM node"},
        {Map.has_key?(by_role, :tts), "a graph needs a TTS node"},
        {Map.has_key?(by_role, :stt) or Map.has_key?(by_role, :vision),
         "a graph needs an STT or vision node"}
      ]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    unsupported =
      for node <- Map.get(by_role, :unsupported, []),
          do:
            "node #{inspect(node.id)}: a session cannot run a #{node.spec.input} to #{node.spec.output} node"

    with [] <- count_errors ++ required_errors ++ unsupported do
      roles = Map.new(by_role, fn {role, [node]} -> {role, node} end)
      ids = Map.new(roles, fn {role, node} -> {node.id, role} end)

      edge_errors =
        for {from, to} = edge <- edges,
            {ids[from], ids[to]} not in @edges,
            do:
              "edge #{edge_name(edge)} is not supported: a session runs input -> STT or vision -> LLM -> TTS"

      # Each node that is present needs its edge in the chain.
      missing =
        for {from_role, to_role} <- @edges,
            Map.has_key?(roles, from_role) or (Map.has_key?(roles, to_role) and to_role != :llm) do
          missing_edge(roles[from_role], from_role, roles[to_role], to_role, edges)
        end
        |> Enum.reject(&is_nil/1)

      case edge_errors ++ missing do
        [] -> {:ok, roles}
        errors -> {:error, errors}
      end
    else
      errors -> {:error, errors}
    end
  end

  defp inputs(max), do: for(kind <- [:audio, :image, :text], do: {{:input, kind}, max})

  defp missing_edge(nil, from_role, to, _, _),
    do: "node #{inspect(to.id)}: no #{role_name(from_role)} node to connect from"

  defp missing_edge(from, _, nil, to_role, _),
    do: "node #{inspect(from.id)}: no #{role_name(to_role)} node to connect to"

  defp missing_edge(from, _, to, _, edges),
    do: if({from.id, to.id} not in edges, do: "missing edge #{edge_name({from.id, to.id})}")

  defp role(%{input: nil, output: kind}), do: {:input, kind}
  defp role(%{input: :audio, output: :text}), do: :stt
  defp role(%{input: :image, output: :text}), do: :vision
  defp role(%{input: :text, output: :text}), do: :llm
  defp role(%{input: :text, output: :audio}), do: :tts
  defp role(_), do: :unsupported

  defp role_name({:input, kind}), do: "#{kind} input"
  defp role_name(role) when role in [:stt, :llm, :tts], do: role |> to_string() |> String.upcase()
  defp role_name(:vision), do: "vision"
end
