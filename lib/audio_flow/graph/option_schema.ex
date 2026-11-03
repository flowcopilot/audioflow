defmodule AudioFlow.Graph.OptionSchema do
  @moduledoc """
  Converts the existing node option descriptors to Zoi schemas.

  Runtime resolution is strict, applies defaults, and collects all errors.
  Form casting validates only submitted fields, without required checks or
  defaults, so incomplete graphs remain editable. It accepts both the atom-key
  node descriptors and their JSON metadata representation; user keys never
  become atoms.
  """

  @doc "Resolves string-keyed options to the trusted descriptor names."
  def resolve(specs, given) do
    names = Enum.map(specs, &to_string(&1.name))
    unknown = for key <- Map.keys(given), key not in names, do: {:unknown, key}

    Enum.reduce(specs, {%{}, unknown}, fn spec, {options, errors} ->
      # Historically explicit nil and an absent option both request its default.
      value = Map.get(given, to_string(spec.name))
      input = if is_nil(value), do: %{}, else: %{"value" => value}
      schema = Zoi.map(%{"value" => field(spec)})

      case Zoi.parse(schema, input) do
        {:ok, %{"value" => value}} ->
          {Map.put(options, spec.name, value), errors}

        {:ok, %{}} ->
          {options, errors}

        {:error, _} ->
          {options, errors ++ [{spec.name, failure(spec, value)}]}
      end
    end)
  end

  defp failure(_spec, nil), do: :required
  defp failure(spec, _value), do: {:invalid, spec.type}

  defp field(spec) do
    schema = type(spec.type)

    cond do
      Map.has_key?(spec, :default) -> Zoi.default(schema, spec.default)
      spec[:required] -> schema
      true -> Zoi.optional(schema)
    end
  end

  defp type(:string), do: Zoi.string()
  defp type(:integer), do: Zoi.integer()
  defp type(:boolean), do: Zoi.boolean()
  defp type(:positive), do: Zoi.integer() |> Zoi.positive()
  defp type({:enum, values}), do: Zoi.enum(values)

  @doc false
  def type_name({:enum, values}), do: "one of #{Enum.map_join(values, ", ", &inspect/1)}"
  def type_name(:positive), do: "a positive integer"
  def type_name(type), do: "a #{type}"

  @doc "Casts a submitted form field, or returns :skip / :empty for partial edits."
  def cast(_spec, nil), do: :skip

  def cast(spec, value) do
    type = descriptor_type(spec)

    cond do
      type == :boolean -> validate_form(type, value in ["true", "on", true])
      not is_binary(value) -> {:error, "has an incorrect value"}
      String.trim(value) == "" -> :empty
      true -> cast_value(type, value)
    end
  end

  defp descriptor_type(%{type: type}), do: type
  defp descriptor_type(%{"type" => "string"}), do: :string
  defp descriptor_type(%{"type" => "integer"}), do: :integer
  defp descriptor_type(%{"type" => "boolean"}), do: :boolean
  defp descriptor_type(%{"type" => "enum", "values" => values}), do: {:enum, values}

  defp cast_value(:integer = type, value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> validate_form(type, integer)
      _ -> {:error, "must be an integer"}
    end
  end

  defp cast_value({:enum, values} = type, value) do
    case find_item(values, value) do
      {:ok, item} -> validate_form(type, item)
      nil -> {:error, "must be one of #{Enum.map_join(values, ", ", &to_string/1)}"}
    end
  end

  defp cast_value(type, value), do: validate_form(type, value)

  defp find_item(values, value),
    do: Enum.find_value(values, &if(to_string(&1) == value, do: {:ok, &1}))

  defp validate_form(type, value) do
    case Zoi.parse(type(type), value) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, "must be #{type_name(type)}"}
    end
  end
end
