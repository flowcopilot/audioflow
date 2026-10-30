defmodule AudioFlowUI.TestGraphs do
  @moduledoc false

  def clear,
    do: for(graph <- AudioFlowUI.Graphs.list(), do: AudioFlowUI.Graphs.delete(graph["id"]))

  def voice(id \\ "voice") do
    %{
      "id" => id,
      "name" => "Voice",
      "nodes" => [
        %{"id" => "keys", "type" => "input.text"},
        %{"id" => "mic", "type" => "input.audio"},
        %{"id" => "stt", "type" => "demo.stt"},
        %{"id" => "llm", "type" => "demo.llm"},
        %{"id" => "tts", "type" => "demo.tts"}
      ],
      "edges" => [
        %{"from" => "keys", "to" => "llm"},
        %{"from" => "mic", "to" => "stt"},
        %{"from" => "stt", "to" => "llm"},
        %{"from" => "llm", "to" => "tts"}
      ]
    }
  end
end
