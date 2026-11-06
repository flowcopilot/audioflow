defmodule AudioFlow.Graph.Nodes.ChatHTTP do
  @moduledoc "ReqLLM inference nodes, including the deprecated chat-completions configuration node."
  @behaviour AudioFlow.Graph.Node

  @impl true
  def nodes do
    [
      %{
        type: "llm.chat_http",
        title: "Chat completions LLM (deprecated)",
        description: "A compatible local server or cloud endpoint.",
        input: :text,
        output: :text,
        history: true,
        options: [
          %{name: :endpoint, type: :string, required: true, description: "Chat-completions URL."},
          %{name: :model, type: :string, required: true, description: "Model name."},
          %{name: :system, type: :string, description: "System instruction."},
          %{
            name: :tools_profile,
            type: :string,
            description: "Trusted chat tool profile in application configuration."
          },
          %{
            name: :api_key_env,
            type: :string,
            description: "Name of the environment variable with the API key."
          },
          %{name: :timeout_ms, type: :integer, default: 30_000, description: "Request deadline."}
        ]
      }
    ] ++
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
            %{
              name: :timeout_ms,
              type: :integer,
              default: 30_000,
              description: "Request deadline."
            }
          ]
        }
      ]
  end

  def adapter("llm.req_llm", options) do
    tools =
      if profile = options[:tools_profile],
        do: Map.fetch!(Application.get_env(:audio_flow, :chat_tool_profiles, %{}), profile),
        else: []

    key = if env = options[:api_key_env], do: System.get_env(env), else: nil
    opts = [model: options.model, audio_flow: [tools: tools, timeout_ms: options.timeout_ms]]

    opts =
      Enum.reduce([:base_url, :system_prompt], opts, fn name, opts ->
        if value = options[name], do: Keyword.put(opts, name, value), else: opts
      end)

    {AudioFlow.Adapters.ReqLLM, if(key, do: Keyword.put(opts, :api_key, key), else: opts)}
  end

  @impl true
  def adapter("llm.chat_http", options) do
    # The graph stores the variable name, never the key.
    api_key = if env = options[:api_key_env], do: fn -> System.get_env(env) end

    adapter_options =
      [endpoint: options.endpoint, model: options.model, timeout_ms: options.timeout_ms] ++
        if(options[:system], do: [system: options.system], else: []) ++
        if(api_key, do: [api_key: api_key], else: [])

    tools =
      if profile = options[:tools_profile],
        do: Map.fetch!(Application.get_env(:audio_flow, :chat_tool_profiles, %{}), profile),
        else: []

    {AudioFlow.Adapters.ChatHTTP, Keyword.put(adapter_options, :tools, tools)}
  end
end
