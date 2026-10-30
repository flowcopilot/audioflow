defmodule AudioFlow.GraphTest do
  use ExUnit.Case, async: true
  alias AudioFlow.{Audio, Graph, Text}

  defp voice do
    %{
      "nodes" => [
        %{"id" => "mic", "type" => "input.audio"},
        %{"id" => "keys", "type" => "input.text"},
        %{"id" => "stt", "type" => "demo.stt"},
        %{"id" => "llm", "type" => "demo.llm"},
        %{"id" => "tts", "type" => "demo.tts", "position" => %{"x" => 600, "y" => 0}}
      ],
      "edges" => [
        %{"from" => "mic", "to" => "stt"},
        %{"from" => "keys", "to" => "llm"},
        %{"from" => "stt", "to" => "llm"},
        %{"from" => "llm", "to" => "tts"}
      ],
      "settings" => %{"timeout_ms" => 5_000}
    }
  end

  defp errors(graph) do
    assert {:error, errors} = Graph.validate(graph, Graph.catalog())
    errors
  end

  defp update_node(graph, id, fun),
    do:
      update_in(
        graph["nodes"],
        &Enum.map(&1, fn node -> if node["id"] == id, do: fun.(node), else: node end)
      )

  defp put_edges(graph, edges), do: Map.put(graph, "edges", edges)

  test "a valid graph runs as a session with its adapters and settings" do
    graph = put_in(voice(), ["settings", "history"], true)
    assert {:ok, options} = Graph.session_options(graph, Graph.catalog())
    assert options[:history] == true
    # The demo LLM accepts only a string prompt, not history messages.
    assert {:ok, options} = Graph.session_options(voice(), Graph.catalog())
    assert options[:timeout_ms] == 5_000
    refute Keyword.has_key?(options, :vision)

    {:ok, session} = AudioFlow.start_session(options)
    {:ok, turn} = AudioFlow.submit(session, %Audio{data: <<0, 0>>, sample_rate: 16_000})
    assert_receive {AudioFlow, ^session, ^turn, {:transcript, "Hello"}}
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "Hi"})
    assert_receive {AudioFlow, ^session, ^turn, {:text, "You said: " <> _}}
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
  end

  test "atom keys are accepted" do
    graph = %{
      nodes: [
        %{id: "mic", type: "input.audio"},
        %{id: "stt", type: "demo.stt"},
        %{id: "llm", type: "demo.llm"},
        %{id: "tts", type: "demo.tts"}
      ],
      edges: [%{from: "mic", to: "stt"}, %{from: "stt", to: "llm"}, %{from: "llm", to: "tts"}]
    }

    assert :ok = Graph.validate(graph, Graph.catalog())
  end

  test "node options are checked, and defaults and secrets reach the adapter" do
    options = %{"endpoint" => "http://localhost:1/v1/chat/completions", "model" => 1}
    graph = update_node(voice(), "llm", &%{&1 | "type" => "llm.chat_http"})
    graph = update_node(graph, "llm", &Map.put(&1, "options", options))
    assert errors(graph) == [~s(node "llm": option model must be a string)]

    options = %{options | "model" => "qwen3"} |> Map.put("api_key_env", "KEY")
    graph = update_node(graph, "llm", &Map.put(&1, "options", options))
    assert {:ok, session} = Graph.session_options(graph, Graph.catalog())
    assert {AudioFlow.Adapters.ChatHTTP, adapter} = session[:llm]
    assert adapter[:timeout_ms] == 30_000
    assert is_function(adapter[:api_key], 0)

    graph = update_node(graph, "llm", &put_in(&1, ["options", "token"], "x"))
    assert errors(graph) == [~s(node "llm": unknown option "token")]
  end

  test "node and edge errors are all reported" do
    graph = %{
      "nodes" => [
        %{"id" => "mic", "type" => "input.audio"},
        %{"id" => "mic", "type" => "demo.stt"},
        %{"id" => "x", "type" => "nope"},
        %{"id" => "tts", "type" => "demo.tts"}
      ],
      "edges" => [
        %{"from" => "mic", "to" => "tts"},
        %{"from" => "tts", "to" => "ghost"},
        %{"from" => "mic", "to" => "tts"}
      ],
      "settings" => %{"history" => "yes", "color" => "red"}
    }

    assert errors(graph) == [
             ~s(duplicate node id "mic"),
             ~s(node "x": unknown type "nope"),
             ~s(edge "mic" -> "tts": audio output cannot connect to text input),
             ~s(edge refers to unknown node "ghost"),
             ~s(edge "mic" -> "tts": audio output cannot connect to text input),
             "unknown setting \"color\"",
             "setting history must be a boolean"
           ]
  end

  test "the graph must have the session shape" do
    assert errors(%{"nodes" => []}) == [
             "a graph needs an LLM node",
             "a graph needs a TTS node",
             "a graph needs an STT or vision node"
           ]

    assert errors(put_edges(voice(), [])) == [
             ~s(missing edge "mic" -> "stt"),
             ~s(missing edge "keys" -> "llm"),
             ~s(missing edge "stt" -> "llm"),
             ~s(missing edge "llm" -> "tts")
           ]

    assert errors(
             Map.update!(voice(), "nodes", &(&1 ++ [%{"id" => "llm2", "type" => "demo.llm"}]))
           ) ==
             ["a graph can have only one node of role LLM"]

    # Kinds match, but a session cannot transcribe its own reply.
    looped = Map.update!(voice(), "edges", &(&1 ++ [%{"from" => "tts", "to" => "stt"}]))

    assert errors(looped) == [
             ~s(edge "tts" -> "stt" is not supported: a session runs input -> STT or vision -> LLM -> TTS)
           ]

    no_mic = Map.update!(voice(), "nodes", &Enum.reject(&1, fn node -> node["id"] == "mic" end))
    no_mic = Map.update!(no_mic, "edges", &Enum.reject(&1, fn edge -> edge["from"] == "mic" end))
    assert errors(no_mic) == [~s(node "stt": no audio input node to connect from)]
  end

  test "custom node families join the catalog" do
    defmodule Upper do
      @behaviour AudioFlow.Graph.Node
      def nodes,
        do: [
          %{
            type: "upper.llm",
            title: "Upper",
            description: "",
            input: :text,
            output: :text,
            options: [%{name: :mode, type: {:enum, ["a", "b"]}, default: "a"}]
          }
        ]

      def adapter(_, options),
        do:
          {AudioFlow.Adapters.Function,
           [run: fn input, emit -> emit.(String.upcase(input) <> options.mode) end]}
    end

    catalog = Graph.catalog([AudioFlow.Graph.Nodes.Input, AudioFlow.Graph.Nodes.Demo, Upper])
    assert "upper.llm" in Enum.map(Graph.node_types(catalog), & &1.type)

    graph = update_node(voice(), "llm", &%{&1 | "type" => "upper.llm"})

    assert {:ok, options} = Graph.session_options(graph, catalog)
    {:ok, session} = AudioFlow.start_session(options)
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "hi"})
    assert_receive {AudioFlow, ^session, ^turn, {:text, "HIa"}}

    bad = update_node(graph, "llm", &Map.put(&1, "options", %{"mode" => "c"}))

    assert {:error, [~s(node "llm": option mode must be one of "a", "b")]} =
             Graph.validate(bad, catalog)

    assert_raise ArgumentError, ~r/duplicate node type/, fn -> Graph.catalog([Upper, Upper]) end
  end
end
