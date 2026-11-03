defmodule AudioFlow.Privacy do
  @moduledoc """
  Transcript redaction helpers. A redactor accepts a complete UTF-8 stream and
  returns `{:ok, text}` or `{:error, reason}`. Recorder failures are fail-closed.
  Regex rules only cover the supplied patterns, not arbitrary PII or audio.
  """

  @doc "Build a redactor from explicit `{regex, replacement}` rules."
  def rules(rules) when is_list(rules) do
    unless Enum.all?(rules, fn
             {%Regex{}, replacement} when is_binary(replacement) -> true
             _ -> false
           end),
           do: raise(ArgumentError, "expected {regex, replacement} rules")

    fn text ->
      {:ok,
       Enum.reduce(rules, text, fn {pattern, replacement}, text ->
         Regex.replace(pattern, text, replacement)
       end)}
    end
  end

  @doc false
  def redact(fun, text) do
    case fun.(text) do
      {:ok, redacted} when is_binary(redacted) ->
        if String.valid?(redacted), do: {:ok, redacted}, else: {:error, :redaction_failed}

      _ ->
        {:error, :redaction_failed}
    end
  rescue
    _ -> {:error, :redaction_failed}
  catch
    _, _ -> {:error, :redaction_failed}
  end
end
