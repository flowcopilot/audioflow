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
