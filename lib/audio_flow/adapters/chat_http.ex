defmodule AudioFlow.Adapters.ChatHTTP do
  @moduledoc """
  Deprecated chat-completions configuration shim. Use `AudioFlow.Adapters.ReqLLM`
  with ReqLLM model/context/options directly. No HTTP protocol is implemented here.
  """
  @behaviour AudioFlow.Adapter
  @impl true
  def run(input, options, emit) do
    endpoint = Keyword.fetch!(options, :endpoint)
    uri = URI.parse(endpoint)

    if uri.scheme not in ["http", "https"] or uri.host == nil or uri.userinfo != nil,
      do: raise(ArgumentError, "endpoint must be an HTTP or HTTPS URL without user information")

    parameters =
      Keyword.get(options, :parameters, %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)

    parameters = Map.drop(parameters, ["stream", "n"])

    key =
      case options[:api_key] do
        fun when is_function(fun, 0) -> fun.()
        key -> key || "local"
      end

    opts = [
      model: %{provider: :openai, id: Keyword.fetch!(options, :model)},
      base_url: String.replace_suffix(endpoint, "/chat/completions", ""),
      api_key: key,
      system_prompt: Keyword.get(options, :system, AudioFlow.Prompt.default_system()),
      max_tokens:
        Map.get(parameters, "max_completion_tokens", Map.get(parameters, "max_tokens", 128)),
      req_http_options: [headers: Keyword.get(options, :headers, [])],
      audio_flow:
        Keyword.drop(options, [:endpoint, :model, :api_key, :system, :parameters, :headers])
    ]

    opts =
      if parameters["temperature"],
        do: Keyword.put(opts, :temperature, parameters["temperature"] * 1.0),
        else: opts

    AudioFlow.Adapters.ReqLLM.run(input, opts, emit)
  end
end
