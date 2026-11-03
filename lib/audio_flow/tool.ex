defmodule AudioFlow.Tool do
  @moduledoc """
  A function that an LLM adapter can call during a turn.

  `new/1` accepts a `Jido.Action` module or a map with these keys:

    * `:name` - 1 to 64 ASCII letters, digits, `_`, or `-`.
    * `:description` - text for the model.
    * `:parameters` - JSON Schema object for the arguments. Defaults to an
      empty object.
    * `:run` - a one-argument function. It receives the decoded argument map
      with string keys and returns `{:ok, result}` or `{:error, reason}`.

  A Jido action gets its name, description, and parameter schema from the
  action. It runs with `Jido.Exec.run/4` in the calling process, without Jido
  retries or Jido timeouts. The action context is the `:tool_context` option of
  the adapter.

  `call/3` runs the tool in a linked process. If the turn stops, the tool stops.
  The result is always a string for the model: a binary result stays as it is,
  other results are JSON-encoded. Failures, exceptions, timeouts, and oversized
  results become a JSON object with an `"error"` key. The model can then tell
  the user about the failure.
  """
  @enforce_keys [:name, :description, :parameters, :run]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          run: (map(), map() -> {:ok, term()} | {:error, term()})
        }

  @name ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @spec new(module() | map() | t()) :: t()
  def new(%__MODULE__{} = tool), do: tool

  def new(module) when is_atom(module) do
    if not (Code.ensure_loaded?(module) and function_exported?(module, :__action_metadata__, 0)),
      do: raise(ArgumentError, "#{inspect(module)} is not a Jido action")

    tool = Jido.Action.Tool.to_tool(module)

    build(tool.name, tool.description || "", tool.parameters_schema, fn arguments, context ->
      params = Jido.Action.Tool.convert_params_using_schema(arguments, module.schema())
      Jido.Exec.run(module, params, context, timeout: 0, max_retries: 0)
    end)
  end

  def new(%{name: name, run: run} = tool) when is_function(run, 1) do
    build(
      name,
      Map.get(tool, :description, ""),
      Map.get(tool, :parameters, %{"type" => "object", "properties" => %{}}),
      fn arguments, _context -> run.(arguments) end
    )
  end

  def new(other), do: raise(ArgumentError, "invalid tool: #{inspect(other)}")

  defp build(name, description, parameters, run) do
    name = to_string(name)

    if not Regex.match?(@name, name),
      do: raise(ArgumentError, "tool name #{inspect(name)} is invalid")

    if not is_binary(description),
      do: raise(ArgumentError, "tool #{name} description must be a string")

    if not is_map(parameters),
      do: raise(ArgumentError, "tool #{name} parameters must be a JSON Schema map")

    %__MODULE__{name: name, description: description, parameters: parameters, run: run}
  end

  @doc "Returns the chat-completions `tools` entry for the tool."
  @spec spec(t()) :: map()
  def spec(%__MODULE__{} = tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => tool.parameters
      }
    }
  end

  @doc """
  Runs the tool and returns the result text for the model.

  Options: `:context` (map, `%{}`), `:timeout_ms` (10,000), and
  `:max_result_bytes` (8,192).
  """
  @spec call(t(), map(), keyword()) :: String.t()
  def call(%__MODULE__{} = tool, arguments, options \\ []) when is_map(arguments) do
    context = Keyword.get(options, :context, %{})
    timeout = Keyword.get(options, :timeout_ms, 10_000)
    limit = Keyword.get(options, :max_result_bytes, 8_192)

    task =
      Task.async(fn ->
        try do
          tool.run.(arguments, context)
        rescue
          error -> {:error, Exception.message(error)}
        catch
          kind, reason -> {:error, Exception.format_banner(kind, reason)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> encode(result, limit)
      {:ok, {:error, reason}} -> error(reason)
      {:ok, other} -> error("invalid tool result: #{inspect(other, limit: 10)}")
      {:exit, reason} -> error("tool exited: #{Exception.format_exit(reason)}")
      nil -> error("tool timed out after #{timeout} ms")
    end
  end

  defp encode(result, limit) do
    text =
      if is_binary(result) and String.valid?(result) do
        {:ok, result}
      else
        try do
          {:ok, result |> Jido.Action.Sanitizer.sanitize() |> JSON.encode!()}
        rescue
          _ -> :error
        end
      end

    case text do
      {:ok, text} when byte_size(text) <= limit -> text
      {:ok, _} -> error("tool result is larger than #{limit} bytes")
      :error -> error("tool result cannot be encoded as JSON")
    end
  end

  defp error(reason) when is_exception(reason), do: error(Exception.message(reason))
  defp error(reason) when is_binary(reason), do: JSON.encode!(%{"error" => reason})
  defp error(reason), do: error(inspect(reason, limit: 20))
end
