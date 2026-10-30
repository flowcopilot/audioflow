defmodule AudioFlow.GraphTest do
  use ExUnit.Case, async: true
  alias AudioFlow.{Audio, Graph, Image, Text}

  # Test nodes. `split` streams two chunks per input, `join` and `echo` record
  # what they receive, and `history` reports how many messages it receives.
  defmodule TestNodes do
    @behaviour AudioFlow.Graph.Node

    def nodes do
      [
        spec("test.split", :text, :text, input_mode: :stream),
        spec("test.join", :text, :text, []),
        spec("test.echo", :text, :text, input_mode: :stream),
        spec("test.history", :text, :text, history: true),
        spec("test.speak", :text, :audio, input_mode: :stream)
      ]
    end

    def adapter("test.split", _),
      do: fun(fn input, emit -> Enum.each(["1 ", "2 "], &emit.(input <> &1)) end)

    def adapter("test.join", _), do: fun(fn input, emit -> emit.("joined[#{input}]") end)
    def adapter("test.echo", _), do: fun(fn input, emit -> emit.("echo[#{input}]") end)

    def adapter("test.history", _),
      do: fun(fn messages, emit -> emit.("messages=#{length(messages)}") end)

    def adapter("test.speak", _),
      do: fun(fn _, emit -> emit.(%Audio{data: <<1, 0>>, sample_rate: 16_000}) end)

    defp fun(run), do: {AudioFlow.Adapters.Function, [run: run]}

    defp spec(type, input, output, extra),
      do:
        Map.merge(
          %{type: type, title: type, description: "", input: input, output: output, options: []},
          Map.new(extra)
        )
  end

  defmodule Output do
    @behaviour AudioFlow.Output
    def start_turn(_, _), do: :ok

    def push(owner, _, audio) do
      send(owner, {:pushed, audio})
      :ok
    end

    def finish(_, _), do: :ok
    def flush(_, _), do: :ok
  end

  defp catalog, do: Graph.catalog([Graph.Nodes.Input, Graph.Nodes.Demo, TestNodes])

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

  defp graph(nodes, edges, settings \\ %{}) do
    %{
      "nodes" => for({id, type} <- nodes, do: %{"id" => id, "type" => type}),
      "edges" => for({from, to} <- edges, do: %{"from" => from, "to" => to}),
      "settings" => settings
    }
  end

  defp errors(graph, catalog \\ Graph.catalog()) do
    assert {:error, errors} = Graph.validate(graph, catalog)
    errors
  end

  defp update_node(graph, id, fun),
    do:
      update_in(
        graph["nodes"],
        &Enum.map(&1, fn node -> if node["id"] == id, do: fun.(node), else: node end)
      )

  defp start(graph, catalog \\ catalog(), options \\ []) do
    assert {:ok, session_options} = Graph.session_options(graph, catalog)
    {:ok, session} = AudioFlow.start_session(session_options ++ options)
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    session
  end

  defp events(session, input) do
    {:ok, turn} = AudioFlow.submit(session, input)
    collect(session, turn, [])
  end

  defp collect(session, turn, events) do
    receive do
      {AudioFlow, ^session, ^turn, {:done, _}} ->
        Enum.reverse(events)

      {AudioFlow, ^session, ^turn, {:error, reason, _}} ->
        flunk("turn failed: #{inspect(reason)}")

      {AudioFlow, ^session, ^turn, event} ->
        collect(session, turn, [event | events])
    after
      1000 -> flunk("turn did not finish")
    end
  end

  test "a graph session reports each output with its node, for each input kind" do
    session = start(voice(), Graph.catalog(), output: {Output, self()})
    audio = %Audio{data: <<0, 0>>, sample_rate: 16_000}

    assert [
             {:transcript, "Hello", "stt"},
             {:text, "You said: Hello.", "llm"},
             {:audio, %Audio{} = pcm, "tts"}
           ] = events(session, audio)

    assert_received {:pushed, ^pcm}

    assert [{:text, "You said: Hi.", "llm"}, {:audio, _, "tts"}] =
             events(session, %Text{data: " Hi "})

    image = %Image{data: <<0, 0, 0>>, width: 1, height: 1}
    assert {:error, {:unsupported_input, :image}} = AudioFlow.submit(session, image)
  end

  test "stream nodes run per value, join nodes run once on all their sources" do
    session =
      graph(
        [
          {"in", "input.text"},
          {"split", "test.split"},
          {"echo", "test.echo"},
          {"join", "test.join"}
        ],
        [{"in", "split"}, {"split", "echo"}, {"split", "join"}, {"in", "join"}]
      )
      |> start()

    assert events(session, %Text{data: "x"}) == [
             {:text, "x1 ", "split"},
             {:text, "echo[x1 ]", "echo"},
             {:text, "x2 ", "split"},
             {:text, "echo[x2 ]", "echo"},
             # Sources join in edge order, not in arrival order.
             {:text, "joined[x1 x2\nx]", "join"}
           ]
  end

  test "the history node receives the conversation and saves its reply" do
    session =
      graph(
        [{"in", "input.text"}, {"llm", "test.history"}, {"speak", "test.speak"}],
        [{"in", "llm"}, {"llm", "speak"}],
        %{"history" => true}
      )
      |> start()

    assert [{:text, "messages=1", "llm"}, {:audio, _, "speak"}] =
             events(session, %Text{data: "a"})

    assert [{:text, "messages=3", "llm"}, _] = events(session, %Text{data: "b"})
  end

  test "node options are checked, and defaults and secrets reach the adapter" do
    options = %{"endpoint" => "http://localhost:1/v1/chat/completions", "model" => 1}
    graph = update_node(voice(), "llm", &%{&1 | "type" => "llm.chat_http"})
    graph = update_node(graph, "llm", &Map.put(&1, "options", options))
    assert errors(graph) == [~s(node "llm": option model must be a string)]

    options = %{options | "model" => "qwen3"} |> Map.put("api_key_env", "KEY")
    graph = update_node(graph, "llm", &Map.put(&1, "options", options))
    assert {:ok, session} = Graph.session_options(graph, Graph.catalog())
    assert {AudioFlow.Adapters.ChatHTTP, adapter} = session[:graph].steps["llm"].adapter
    assert adapter[:timeout_ms] == 30_000
    assert is_function(adapter[:api_key], 0)
    assert session[:timeout_ms] == 5_000

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

  test "a graph needs inputs, paths from them, no cycles, and one history node" do
    assert errors(graph([{"llm", "demo.llm"}], [])) == [
             "a graph needs an input node",
             ~s(node "llm" has no path from an input node)
           ]

    looped =
      graph(
        [{"in", "input.text"}, {"a", "test.echo"}, {"b", "test.echo"}],
        [{"in", "a"}, {"a", "b"}, {"b", "a"}]
      )

    assert errors(looped, catalog()) == [~s(edges form a cycle: "a" -> "b" -> "a")]

    two =
      graph([{"in", "input.text"}, {"a", "demo.llm"}, {"b", "demo.llm"}], [
        {"in", "a"},
        {"in", "b"}
      ])

    assert :ok = Graph.validate(two, Graph.catalog())

    assert errors(Map.put(two, "settings", %{"history" => true})) == [
             ~s(the history setting allows only one node that accepts history, found "a", "b")
           ]

    assert errors(graph([{"in", "input.text"}], [], %{"history" => true})) == [
             "the history setting needs a node that accepts history, such as an LLM node"
           ]
  end

  test "atom keys are accepted" do
    graph = %{
      nodes: [%{id: "mic", type: "input.audio"}, %{id: "stt", type: "demo.stt"}],
      edges: [%{from: "mic", to: "stt"}]
    }

    assert :ok = Graph.validate(graph, Graph.catalog())
  end

  test "a catalog rejects duplicate types and invalid specs" do
    assert_raise ArgumentError, ~r/duplicate node type/, fn ->
      Graph.catalog([TestNodes, TestNodes])
    end

    defmodule BadNodes do
      def nodes,
        do: [
          %{
            type: "bad",
            title: "",
            description: "",
            input: :audio,
            output: :text,
            options: [],
            history: true
          }
        ]
    end

    assert_raise ArgumentError, ~r/history node needs a joined text input/, fn ->
      Graph.catalog([BadNodes])
    end
  end

  test "resampling keeps the duration and interpolates between samples" do
    pcm = for sample <- [0, 300, 600, 900], into: <<>>, do: <<sample::little-signed-16>>
    audio = %Audio{data: pcm, sample_rate: 8_000}

    assert %Audio{data: data, sample_rate: 16_000} = Graph.Nodes.Audio.resample(audio, 16_000)

    assert for(<<sample::little-signed-16 <- data>>, do: sample) == [
             0,
             150,
             300,
             450,
             600,
             750,
             900,
             900
           ]

    assert Graph.Nodes.Audio.resample(audio, 8_000) == audio
  end
end
