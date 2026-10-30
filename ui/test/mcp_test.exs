defmodule AudioFlowUI.MCPTest do
  # The tools share the graph store with the dashboard.
  use ExUnit.Case, async: false
  import Sake.Test
  import AudioFlowUI.TestGraphs

  setup do
    clear()
    on_exit(&clear/0)
    %{client: connect(AudioFlowUI.MCP)}
  end

  test "an agent builds a graph in steps, then runs it", %{client: client} do
    assert {:ok, %{structured: %{"node_types" => types}}} = call_tool(client, "list_node_types")
    llm = Enum.find(types, &(&1["type"] == "llm.chat_http"))
    assert %{"input" => "text", "output" => "text"} = llm

    assert %{"type" => "string", "required" => true} =
             Enum.find(llm["options"], &(&1["name"] == "endpoint"))

    partial = Map.update!(voice(), "edges", &Enum.drop(&1, -1))

    assert {:ok, %{structured: %{"errors" => [~s(missing edge "llm" -> "tts")]}}} =
             call_tool(client, "save_graph", %{"graph" => partial})

    assert {:ok, %{is_error: true, text: ~s(missing edge "llm" -> "tts")}} =
             call_tool(client, "run_graph", %{"id" => "voice", "text" => "Hi"})

    assert {:ok, %{structured: %{"errors" => []}}} =
             call_tool(client, "save_graph", %{"graph" => voice()})

    assert {:ok, %{structured: %{"graphs" => [%{"id" => "voice", "errors" => []}]}}} =
             call_tool(client, "list_graphs")

    assert {:ok, %{structured: result}} =
             call_tool(client, "run_graph", %{"id" => "voice", "text" => "Hi"})

    assert %{"status" => "done", "reply" => "You said: Hi."} = result
    assert [%{"type" => "text"}, %{"type" => "audio", "bytes" => 3200}] = result["events"]
    assert result["metrics"]["first_audio_us"] > 0
  end

  test "validation does not save, and errors name the problem", %{client: client} do
    bad = put_in(voice()["nodes"], [%{"id" => "x", "type" => "nope"}])

    assert {:ok, %{structured: %{"errors" => [~s(node "x": unknown type "nope") | _]}}} =
             call_tool(client, "validate_graph", %{"graph" => bad})

    assert {:ok, %{structured: %{"graphs" => []}}} = call_tool(client, "list_graphs")

    assert {:ok, %{is_error: true, text: "graph id must match" <> _}} =
             call_tool(client, "save_graph", %{"graph" => %{voice() | "id" => "../x"}})

    assert {:ok, %{is_error: true, text: ~s(no graph with id "gone")}} =
             call_tool(client, "get_graph", %{"id" => "gone"})
  end

  test "a save reaches dashboard subscribers, and delete removes the file", %{client: client} do
    AudioFlowUI.Graphs.subscribe()
    assert {:ok, _} = call_tool(client, "save_graph", %{"graph" => voice()})
    assert_receive {:graph_saved, %{"id" => "voice"}}

    path = Path.join(Application.fetch_env!(:audio_flow_ui, :data_dir), "voice.json")
    assert {:ok, %{"name" => "Voice"}} = path |> File.read!() |> Jason.decode()

    assert {:ok, %{is_error: false}} = call_tool(client, "delete_graph", %{"id" => "voice"})
    assert_receive {:graph_deleted, "voice"}
    refute File.exists?(path)
  end
end
