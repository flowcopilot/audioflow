defmodule AudioFlowUI.GraphEdits do
  @moduledoc """
  Editor changes to a graph map. Each function returns `{:ok, graph}` or
  `{:error, message}` and does not save. A graph can be incomplete, so these
  functions refuse only changes that cannot be correct in any graph: an edge
  to an unknown node, a self-loop, a duplicate edge, or an edge between ports
  of different kinds.
  """

  @doc "Sets the `\"position\"` of a node."
  def move_node(graph, id, x, y) when is_number(x) and is_number(y) do
    update_node(graph, id, &Map.put(&1, "position", %{"x" => round(x), "y" => round(y)}))
  end

  def move_node(_graph, _id, _x, _y), do: {:error, "position must be numbers"}

  @doc "Adds the edge `from -> to` if the output kind of `from` is the input kind of `to`."
  def connect(graph, from, to, types) do
    with {:ok, source} <- fetch_node(graph, from),
         {:ok, target} <- fetch_node(graph, to),
         :ok <- check_edge(graph, source, target, types) do
      {:ok, Map.put(graph, "edges", edges(graph) ++ [%{"from" => from, "to" => to}])}
    end
  end

  @doc "Removes the edge `from -> to`."
  def disconnect(graph, from, to) do
    {kept, removed} = Enum.split_with(edges(graph), &(not edge?(&1, from, to)))

    if removed == [],
      do: {:error, "no edge #{inspect(from)} -> #{inspect(to)}"},
      else: {:ok, Map.put(graph, "edges", kept)}
  end

  @doc "Removes a node and its edges."
  def delete_node(graph, id) do
    with {:ok, _} <- fetch_node(graph, id) do
      {:ok,
       graph
       |> Map.put("nodes", Enum.reject(nodes(graph), &(&1["id"] == id)))
       |> Map.put("edges", Enum.reject(edges(graph), &(&1["from"] == id or &1["to"] == id)))}
    end
  end

  @doc """
  Adds a node of `type` at `{x, y}`, or below it if a node is already there.
  The id comes from the type: `"demo.stt"` gives `"stt"`, then `"stt_2"`.
  """
  def add_node(graph, type, {x, y}, types) do
    if Map.has_key?(types, type) do
      taken = MapSet.new(nodes(graph), & &1["position"])
      position = free_position(taken, round(x), round(y))
      node = %{"id" => unique_id(graph, type), "type" => type, "position" => position}
      {:ok, Map.put(graph, "nodes", nodes(graph) ++ [node])}
    else
      {:error, "unknown node type #{inspect(type)}"}
    end
  end

  @doc """
  Sets the options of a node from form params, cast to the option schema of
  its type. An empty field removes the option. Keys that are not in the schema
  are not changed.
  """
  def set_options(graph, id, params, types) when is_map(params) do
    with {:ok, node} <- fetch_node(graph, id),
         {:ok, spec} <- fetch_type(types, node["type"]),
         {:ok, options} <- cast_options(node["options"] || %{}, spec["options"], params) do
      update_node(graph, id, fn node ->
        if options == %{},
          do: Map.delete(node, "options"),
          else: Map.put(node, "options", options)
      end)
    end
  end

  @doc "Sets the graph name."
  def rename(graph, name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, "the name must not be empty"}
      name -> {:ok, Map.put(graph, "name", name)}
    end
  end

  @doc "Returns the first of `base`, `base-2`, `base-3`, ... that is not in `taken`."
  def unique(base, taken, separator \\ "-") do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}#{separator}#{n}"
    end)
    |> Enum.find(&(&1 not in taken))
  end

  defp nodes(graph), do: graph["nodes"] || []
  defp edges(graph), do: graph["edges"] || []

  defp edge?(edge, from, to), do: edge["from"] == from and edge["to"] == to

  defp fetch_node(graph, id) do
    case Enum.find(nodes(graph), &(&1["id"] == id)) do
      nil -> {:error, "no node #{inspect(id)}"}
      node -> {:ok, node}
    end
  end

  defp fetch_type(types, type) do
    case Map.fetch(types, type) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, "unknown node type #{inspect(type)}"}
    end
  end

  defp update_node(graph, id, fun) do
    with {:ok, _} <- fetch_node(graph, id) do
      {:ok,
       Map.put(
         graph,
         "nodes",
         Enum.map(nodes(graph), &if(&1["id"] == id, do: fun.(&1), else: &1))
       )}
    end
  end

  defp check_edge(graph, source, target, types) do
    output = get_in(types, [source["type"], "output"])
    input = get_in(types, [target["type"], "input"])

    cond do
      source["id"] == target["id"] ->
        {:error, "a node cannot connect to itself"}

      Enum.any?(edges(graph), &edge?(&1, source["id"], target["id"])) ->
        {:error, "the edge #{inspect(source["id"])} -> #{inspect(target["id"])} exists"}

      output == nil ->
        {:error, "node #{inspect(source["id"])} has no output"}

      input == nil ->
        {:error, "node #{inspect(target["id"])} has no input"}

      output != input ->
        {:error, "#{output} output cannot connect to #{input} input"}

      true ->
        :ok
    end
  end

  defp unique_id(graph, type) do
    base =
      type
      |> String.split(".")
      |> List.last()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")

    unique(base, MapSet.new(nodes(graph), & &1["id"]), "_")
  end

  defp free_position(taken, x, y) do
    position = %{"x" => x, "y" => y}
    if position in taken, do: free_position(taken, x + 40, y + 40), else: position
  end

  defp cast_options(options, schema, params) do
    Enum.reduce_while(schema, {:ok, options}, fn option, {:ok, options} ->
      name = option["name"]

      case cast(option, Map.get(params, name)) do
        :skip -> {:cont, {:ok, options}}
        :empty -> {:cont, {:ok, Map.delete(options, name)}}
        {:ok, value} -> {:cont, {:ok, Map.put(options, name, value)}}
        {:error, message} -> {:halt, {:error, "option #{name} #{message}"}}
      end
    end)
  end

  # A field that the form did not send is not changed.
  defp cast(_option, nil), do: :skip
  defp cast(%{"type" => "boolean"}, value), do: {:ok, value in ["true", "on", true]}

  defp cast(option, value) when is_binary(value) do
    if String.trim(value) == "", do: :empty, else: cast_value(option, value)
  end

  defp cast(_option, _value), do: {:error, "has an incorrect value"}

  defp cast_value(%{"type" => "string"}, value), do: {:ok, value}

  defp cast_value(%{"type" => "integer"}, value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, "must be an integer"}
    end
  end

  defp cast_value(%{"type" => "enum", "values" => values}, value) do
    case Enum.find(values, &(to_string(&1) == value)) do
      nil -> {:error, "must be one of #{Enum.map_join(values, ", ", &to_string/1)}"}
      found -> {:ok, found}
    end
  end

  defp cast_value(_option, value), do: {:ok, value}
end
