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
