defmodule AudioFlowUIWeb.EditorTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import AudioFlowUI.TestGraphs

  @endpoint AudioFlowUIWeb.Endpoint

  defmodule Nodes do
    @moduledoc false
    @behaviour AudioFlow.Graph.Node

    @impl true
    def nodes do
      [
        %{
          type: "test.tool",
          title: "Test tool",
          description: "Has one option of each type.",
          input: :text,
          output: :text,
          options: [
            %{name: :label, type: :string},
            %{name: :key, type: :string, required: true},
            %{name: :retries, type: :integer, default: 1},
            %{name: :verbose, type: :boolean},
            %{name: :mode, type: {:enum, ["fast", "slow"]}}
          ]
        }
      ]
    end
  end

  setup do
    clear()
    on_exit(&clear/0)
    {:ok, _} = AudioFlowUI.Graphs.put(voice())
    %{conn: build_conn()}
  end

  test "hook events move, connect, disconnect, and delete", %{conn: conn} do
    {:ok, view, _} = live(conn, "/graphs/voice")

    render_hook(view, "move_node", %{"id" => "stt", "x" => 400, "y" => 40})
    assert %{"position" => %{"x" => 400, "y" => 40}} = stored_node("stt")
    assert has_element?(view, ~s(#canvas-node-stt[data-x="400"][data-y="40"]))

    render_hook(view, "disconnect", %{"from" => "llm", "to" => "tts"})
    refute %{"from" => "llm", "to" => "tts"} in graph()["edges"]
    refute has_element?(view, ~s([data-edge][data-from="llm"][data-to="tts"]))

    render_hook(view, "connect", %{"from" => "llm", "to" => "tts"})
    assert %{"from" => "llm", "to" => "tts"} in graph()["edges"]
    assert has_element?(view, ~s([data-edge][data-from="llm"][data-to="tts"]))

    render_hook(view, "delete_node", %{"id" => "stt"})
    refute Enum.any?(graph()["nodes"], &(&1["id"] == "stt"))
    refute Enum.any?(graph()["edges"], &("stt" in [&1["from"], &1["to"]]))
    refute has_element?(view, "#canvas-node-stt")
  end

  test "connect refuses edges that cannot be correct", %{conn: conn} do
    {:ok, view, _} = live(conn, "/graphs/voice")
    edges = graph()["edges"]

    for {from, to, message} <- [
          {"llm", "ghost", ~s(no node &quot;ghost&quot;)},
          {"llm", "llm", "a node cannot connect to itself"},
          {"keys", "llm", "exists"},
          {"mic", "llm", "audio output cannot connect to text input"},
          {"tts", "mic", ~s(node &quot;mic&quot; has no input)}
        ] do
      html = render_hook(view, "connect", %{"from" => from, "to" => to})
      assert html =~ message
    end

    assert graph()["edges"] == edges
  end

  test "the palette adds a node with a unique id in the visible area", %{conn: conn} do
    {:ok, view, _} = live(conn, "/graphs/voice")
    render_hook(view, "viewport", %{"x" => 1000, "y" => 0, "width" => 960, "height" => 640})

    view |> element("#palette button", "Demo STT") |> render_click()

    assert %{"type" => "demo.stt", "position" => %{"x" => 1360, "y" => 260}} =
             stored_node("stt_2")

    # The new node is selected, so its panel shows.
    assert has_element?(view, "#node-panel", "stt_2")

    view |> element("#palette button", "Demo STT") |> render_click()
    assert %{"position" => %{"x" => 1400, "y" => 300}} = stored_node("stt_3")
  end

  test "the options form casts values to the option schema", %{conn: conn} do
    nodes = Application.get_env(:audio_flow_ui, :nodes)
    on_exit(fn -> restore(:nodes, nodes) end)

    Application.put_env(:audio_flow_ui, :nodes, [
      AudioFlow.Graph.Nodes.Input,
      AudioFlow.Graph.Nodes.Demo,
      Nodes
    ])

    tool = %{"id" => "tool", "type" => "test.tool", "options" => %{"label" => "old"}}
    {:ok, _} = AudioFlowUI.Graphs.put(Map.update!(voice(), "nodes", &(&1 ++ [tool])))
    {:ok, view, _} = live(conn, "/graphs/voice")
    render_hook(view, "select", %{"node" => "tool"})

    view
    |> form("#node-options", %{
      "options" => %{
        "label" => "",
        "key" => "abc",
        "retries" => "3",
        "verbose" => "true",
        "mode" => "slow"
      }
    })
    |> render_submit()

    assert stored_node("tool")["options"] ==
             %{"key" => "abc", "retries" => 3, "verbose" => true, "mode" => "slow"}

    html =
      view
      |> form("#node-options", %{"options" => %{"retries" => "three"}})
      |> render_submit()

    assert html =~ "option retries must be an integer"
    assert stored_node("tool")["options"]["retries"] == 3
  end

  test "the graph can be renamed", %{conn: conn} do
    {:ok, view, _} = live(conn, "/graphs/voice")
    view |> form("#rename", %{"name" => "  Phone agent "}) |> render_submit()
    assert graph()["name"] == "Phone agent"
  end

  test "New graph makes an empty graph with a unique id and opens it", %{conn: conn} do
    {:ok, list, _} = live(conn, "/")

    assert {:error, {:live_redirect, %{to: "/graphs/graph"}}} =
             list |> element("button", "New graph") |> render_click()

    {:ok, list, _} = live(conn, "/")

    assert {:error, {:live_redirect, %{to: "/graphs/graph-2"}}} =
             list |> element("button", "New graph") |> render_click()

    assert {:ok, %{"nodes" => [], "edges" => []}} = AudioFlowUI.Graphs.get("graph-2")
  end

  defp graph, do: elem(AudioFlowUI.Graphs.get("voice"), 1)
  defp stored_node(id), do: Enum.find(graph()["nodes"], &(&1["id"] == id))

  defp restore(key, nil), do: Application.delete_env(:audio_flow_ui, key)
  defp restore(key, value), do: Application.put_env(:audio_flow_ui, key, value)
end
