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

defmodule AudioFlow.Graph.Nodes.Audio do
  @moduledoc "Audio conversion nodes."
  @behaviour AudioFlow.Graph.Node
  alias AudioFlow.Audio

  @rates [8_000, 16_000, 22_050, 24_000, 44_100, 48_000]

  @impl true
  def nodes do
    [
      %{
        type: "audio.resample",
        title: "Resample",
        description: "Converts the complete PCM input to another sample rate.",
        input: :audio,
        output: :audio,
        options: [
          %{
            name: :sample_rate,
            type: {:enum, @rates},
            default: 16_000,
            description: "Output sample rate in Hz. Whisper needs 16000."
          }
        ]
      }
    ]
  end

  @impl true
  def adapter("audio.resample", %{sample_rate: rate}),
    do: {AudioFlow.Adapters.Function, [run: fn audio, emit -> emit.(resample(audio, rate)) end]}

  @doc "Linear interpolation of mono signed 16-bit PCM."
  def resample(%Audio{sample_rate: rate} = audio, rate), do: audio

  def resample(%Audio{data: data, sample_rate: from}, to) do
    samples = for <<sample::little-signed-16 <- data>>, do: sample
    input = List.to_tuple(samples)
    count = tuple_size(input)
    length = if count == 0, do: 0, else: max(1, div(count * to, from))

    pcm =
      for index <- 0..(length - 1)//1, into: <<>> do
        position = index * from / to
        left = min(trunc(position), count - 1)
        right = min(left + 1, count - 1)
        weight = position - left
        sample = round(elem(input, left) * (1 - weight) + elem(input, right) * weight)
        <<sample::little-signed-16>>
      end

    %Audio{data: pcm, sample_rate: to}
  end
end
