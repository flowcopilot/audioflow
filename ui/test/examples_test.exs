defmodule AudioFlowUI.ExamplesTest do
  use ExUnit.Case, async: false
  alias AudioFlow.Recording.Store
  alias AudioFlowUI.Examples
  alias AudioFlowUI.Prerequisites
  alias AudioFlowUI.Runs

  defmodule EmbeddingFixture do
    @behaviour AudioFlow.Graph.Node
    def nodes,
      do: [
        %{
          type: "fixture.embedding",
          title: "Fixture",
          description: "Synthetic vector",
          input: :text,
          output: :vector,
          options: []
        }
      ]

    def adapter(_, _), do: {AudioFlow.Adapters.Function, run: fn _, emit -> emit.([1.0, 0.0]) end}
  end

  defmodule RetrievalFixture do
    @behaviour AudioFlow.RAG.Backend
    def retrieve(vector, options) when vector == [1.0, 0.0] do
      send(options[:owner], {:retrieval_options, options})
      {:ok, [%{id: "doc-1", content: "Fixture document", metadata: %{}, distance: 0.0}]}
    end
  end

  test "retrieval starter executes the graph with explicit synthetic embedding/backend fixtures" do
    nodes = Application.get_env(:audio_flow_ui, :nodes)
    profiles = Application.get_env(:audio_flow, :retrieval_profiles)

    on_exit(fn ->
      if nodes,
        do: Application.put_env(:audio_flow_ui, :nodes, nodes),
        else: Application.delete_env(:audio_flow_ui, :nodes)

      if profiles,
        do: Application.put_env(:audio_flow, :retrieval_profiles, profiles),
        else: Application.delete_env(:audio_flow, :retrieval_profiles)
    end)

    Application.put_env(:audio_flow_ui, :nodes, [
      AudioFlow.Graph.Nodes.Input,
      AudioFlow.Graph.Nodes.Demo,
      AudioFlow.Graph.Nodes.RAG,
      EmbeddingFixture
    ])

    Application.put_env(:audio_flow, :retrieval_profiles, %{
      "starter" => [
        dimensions: 2,
        backend: {RetrievalFixture, [owner: self()]}
      ]
    })

    graph =
      Examples.starter("rag")
      |> put_in(["nodes", Access.at(1), "type"], "fixture.embedding")
      |> put_in(["nodes", Access.at(1), "options"], %{})

    assert {:ok, %{"status" => "done", "reply" => reply}} = Runs.run_text(graph, "typed query")
    assert reply =~ "Fixture document"
    assert_receive {:retrieval_options, options}
    assert options[:limit] == 5
    assert options[:max_distance] == 2.0
  end

  test "workflow stages a real handoff, rolls back on failure and commits on success" do
    assert %{
             failed_turn: "error",
             state_after_failure: "triage",
             successful_turn: "done",
             state_after_success: "billing"
           } = Examples.workflow()
  end

  test "scripted turns produce actual matches and mismatches and reject malformed scripts" do
    assert {:ok, [%{passed: true}, %{passed: false, reply: "You said: again."}]} =
             Examples.evaluate(Examples.graph(), "Hello => You said: Hello.\nagain => wrong")

    assert {:error, _} = Examples.evaluate(Examples.graph(), "bad script")
    assert {:error, _} = Examples.evaluate(Examples.graph(), String.duplicate("x", 16_385))
  end

  test "recording is opt in, output is email redacted and artifacts are readable and deletable" do
    original = Application.get_env(:audio_flow_ui, :recordings_dir)
    dir = Path.join(System.tmp_dir!(), "ui-recording-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if original,
        do: Application.put_env(:audio_flow_ui, :recordings_dir, original),
        else: Application.delete_env(:audio_flow_ui, :recordings_dir)

      File.rm_rf!(dir)
    end)

    Application.delete_env(:audio_flow_ui, :recordings_dir)

    assert {:error, "Set AUDIOFLOW_UI_RECORDINGS" <> _} =
             Examples.evaluate(Examples.graph(), "x => You said: x.", true)

    Application.put_env(:audio_flow_ui, :recordings_dir, dir)
    assert {:ok, [%{recording: nil}]} = Examples.evaluate(Examples.graph(), "x => You said: x.")
    refute File.exists?(dir)

    assert {:ok, [%{recording: id}]} =
             Examples.evaluate(
               Examples.graph(),
               "me@example.com => You said: me@example.com.",
               true
             )

    {:ok, store} = Store.new(dir)
    assert {:ok, record} = Store.read(store, id)
    assert [%{"text" => "You said: [email]."}] = record["streams"]
    refute Jason.encode!(record) =~ "me@example.com"
    assert :ok = Store.delete(store, id)
  end

  test "provider prerequisites do not leak env values; no mixed-output catalog nodes" do
    env = "ELEVENLABS_API_KEY"
    original = System.get_env(env)

    on_exit(fn ->
      if original, do: System.put_env(env, original), else: System.delete_env(env)
    end)

    graph =
      Examples.starter("tts") |> put_in(["nodes", Access.at(1), "options", "voice_id"], "voice")

    System.delete_env(env)
    assert [message] = Prerequisites.errors(graph)
    assert message =~ env
    assert {:error, [^message]} = Runs.run_text(graph, "hello")
    System.put_env(env, "not-a-real-key")
    assert [] = Prerequisites.errors(graph)
    refute Jason.encode!(AudioFlowUI.node_types()) =~ "not-a-real-key"

    refute Enum.any?(
             AudioFlowUI.node_types(),
             &String.contains?(&1["type"], ["realtime", "gemini"])
           )

    assert {:error, errors} =
             AudioFlow.Graph.session_options(
               put_in(graph, ["nodes", Access.at(1), "options", "api_key"], "browser-secret"),
               AudioFlowUI.catalog()
             )

    assert Enum.any?(errors, &String.contains?(&1, "unknown option"))
  end

  test "RAG without external configuration reports a missing server profile" do
    original = Application.get_env(:audio_flow, :retrieval_profiles)
    Application.delete_env(:audio_flow, :retrieval_profiles)

    on_exit(fn ->
      if original, do: Application.put_env(:audio_flow, :retrieval_profiles, original)
    end)

    assert [message] = Prerequisites.errors(Examples.starter("rag"))
    assert message =~ "database/backend required"
    assert {:error, _} = Examples.evaluate(Examples.starter("rag"), "x => x")
  end

  test "PCM runs use the real graph path and malformed PCM returns an error" do
    graph = AudioFlowUI.TestGraphs.voice()

    assert {:ok, %{"reply" => "You said: Hello.", "status" => "done"}} =
             Runs.run_audio(graph, %AudioFlow.Audio{data: <<0, 0, 1, 0>>, sample_rate: 16_000})

    assert {:error, _} = Runs.run_audio(graph, %AudioFlow.Audio{data: <<1>>, sample_rate: 16_000})
  end

  test "browser playback contains the genuine graph PCM and MCP output stays size-only" do
    graph = AudioFlowUI.TestGraphs.voice()

    assert {:ok, %{"audio" => [%{"url" => "data:audio/wav;base64," <> encoded}]}} =
             Runs.run_browser_text(graph, "hello")

    assert <<"RIFF", _::little-32, "WAVEfmt ", _::binary-size(20), "data", 3200::little-32,
             pcm::binary>> = Base.decode64!(encoded)

    assert pcm == :binary.copy(<<0, 0>>, 1600)
    assert {:ok, %{"audio" => []}} = Runs.run_text(graph, "hello")
  end
end
