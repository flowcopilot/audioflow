defmodule AudioFlow.RuntimeOptions do
  @moduledoc false

  # Validate only owned keys where callers historically ignored extra options.
  # Keep the first duplicate, matching Keyword.get/3 and Keyword.fetch!/2.
  def known!(options, schema, messages \\ []) do
    options
    |> Keyword.take(Keyword.keys(schema))
    |> Enum.uniq_by(&elem(&1, 0))
    |> validate!(schema, messages)
  end

  def validate!(options, schema, messages \\ []) do
    case NimbleOptions.validate(options, schema) do
      {:ok, validated} ->
        validated

      {:error, error} ->
        raise ArgumentError, Map.get(Map.new(messages), error.key, Exception.message(error))
    end
  end
end
