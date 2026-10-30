defmodule AudioFlow.Graph.Nodes.Input do
  @moduledoc "Input nodes. Each one marks an input type that the agent accepts."
  @behaviour AudioFlow.Graph.Node

  @impl true
  def nodes do
    for {kind, title, description} <- [
          {:audio, "Audio input", "Mono 16-bit PCM from a microphone or a file."},
          {:image, "Image input", "RGB images or video frames."},
          {:text, "Text input", "Typed messages. They go directly to the LLM."}
        ] do
      %{
        type: "input.#{kind}",
        title: title,
        description: description,
        input: nil,
        output: kind,
        options: []
      }
    end
  end
end

defmodule AudioFlow.Graph.Nodes.Demo do
  @moduledoc "Synthetic nodes for setup checks. See `AudioFlow.Adapters.Demo`."
  @behaviour AudioFlow.Graph.Node

  @impl true
  def nodes do
    [
      spec("demo.stt", "Demo STT", "Emits a fixed transcript.", :audio, :text,
        event: :transcript
      ),
      spec("demo.llm", "Demo LLM", "Repeats the prompt.", :text, :text, history: true),
      spec("demo.tts", "Demo TTS", "Emits 50 ms of silent PCM.", :text, :audio,
        input_mode: :stream
      )
    ]
  end

  @impl true
  def adapter(type, _options) do
    stage = Map.fetch!(%{"demo.stt" => :stt, "demo.llm" => :llm, "demo.tts" => :tts}, type)
    {AudioFlow.Adapters.Demo, [stage: stage]}
  end

  defp spec(type, title, description, input, output, extra) do
    Map.merge(
      %{
        type: type,
        title: title,
        description: description,
        input: input,
        output: output,
        options: []
      },
      Map.new(extra)
    )
  end
end

defmodule AudioFlow.Graph.Nodes.ChatHTTP do
  @moduledoc "An LLM node over a chat-completions endpoint. See `AudioFlow.Adapters.ChatHTTP`."
  @behaviour AudioFlow.Graph.Node

  @impl true
  def nodes do
    [
      %{
        type: "llm.chat_http",
        title: "Chat completions LLM",
        description: "A compatible local server or cloud endpoint.",
        input: :text,
        output: :text,
        history: true,
        options: [
          %{name: :endpoint, type: :string, required: true, description: "Chat-completions URL."},
          %{name: :model, type: :string, required: true, description: "Model name."},
          %{name: :system, type: :string, description: "System instruction."},
          %{
            name: :api_key_env,
            type: :string,
            description: "Name of the environment variable with the API key."
          },
          %{name: :timeout_ms, type: :integer, default: 30_000, description: "Request deadline."}
        ]
      }
    ]
  end

  @impl true
  def adapter("llm.chat_http", options) do
    # The graph stores the variable name, never the key.
    api_key = if env = options[:api_key_env], do: fn -> System.get_env(env) end

    adapter_options =
      [endpoint: options.endpoint, model: options.model, timeout_ms: options.timeout_ms] ++
        if(options[:system], do: [system: options.system], else: []) ++
        if(api_key, do: [api_key: api_key], else: [])

    {AudioFlow.Adapters.ChatHTTP, adapter_options}
  end
end
