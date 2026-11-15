defmodule AudioFlow.Graph.Nodes.ReqLLM do
  @moduledoc "ReqLLM inference nodes: the `llm.req_llm` node, run by `AudioFlow.Adapters.ReqLLM`."
  @behaviour AudioFlow.Graph.Node

  @impl true
  def nodes do
    [
      %{
        type: "llm.req_llm",
        title: "ReqLLM",
        description: "HTTP LLM inference using ReqLLM models and options.",
        input: :text,
        output: :text,
        history: true,
        options: [
          %{
            name: :model,
            type: :string,
            required: true,
            description: "ReqLLM provider:model specification."
          },
          %{
            name: :base_url,
            type: :string,
            description: "Provider base URL, for example http://localhost:8080/v1."
          },
          %{name: :system_prompt, type: :string, description: "System instruction."},
          %{name: :api_key_env, type: :string, description: "API key environment variable."},
          %{name: :tools_profile, type: :string, description: "Trusted Jido tool profile."},
          %{name: :timeout_ms, type: :integer, default: 30_000, description: "Request deadline."}
        ]
      }
    ]
  end

  @impl true
  def adapter("llm.req_llm", options) do
    key = if env = options[:api_key_env], do: System.get_env(env), else: nil
    tools = if profile = options[:tools_profile], do: profile_tools(profile), else: []

    opts = [
      model: options.model,
      audio_flow: [tools: tools, timeout_ms: options.timeout_ms]
    ]

    opts =
      Enum.reduce([:base_url, :system_prompt], opts, fn name, opts ->
        if value = options[name], do: Keyword.put(opts, name, value), else: opts
      end)

    {AudioFlow.Adapters.ReqLLM, if(key, do: Keyword.put(opts, :api_key, key), else: opts)}
  end

  defp profile_tools(profile),
    do: Map.fetch!(Application.get_env(:audio_flow, :chat_tool_profiles, %{}), profile)
end
