defmodule AudioFlowUIWeb.WebTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import AudioFlowUI.TestGraphs

  @endpoint AudioFlowUIWeb.Endpoint

  setup do
    clear()
    on_exit(&clear/0)
    {:ok, _} = AudioFlowUI.Graphs.put(voice())
    %{conn: build_conn()}
  end

  test "the list and the canvas follow saves from elsewhere", %{conn: conn} do
    {:ok, list, html} = live(conn, "/")
    assert html =~ "Voice"
    {:ok, _} = AudioFlowUI.Graphs.put(voice("other"))
    assert render(list) =~ "other"

    {:ok, canvas, _} = live(conn, "/graphs/voice")
    assert has_element?(canvas, "#node-stt")
    assert has_element?(canvas, ~s(path[id="llm->tts"]))

    {:ok, _} = AudioFlowUI.Graphs.put(Map.update!(voice(), "edges", &Enum.drop(&1, -1)))
    refute has_element?(canvas, ~s(path[id="llm->tts"]))
    assert render(canvas) =~ ~s(node &quot;tts&quot; has no path from an input node)
  end

  test "a text run shows the reply", %{conn: conn} do
    {:ok, canvas, _} = live(conn, "/graphs/voice")
    canvas |> form("#run", %{"text" => "Hi"}) |> render_submit()
    # The run is a task; the next render shows its result.
    assert_eventually(fn -> render(canvas) =~ "You said: Hi." end)
  end

  test "the MCP endpoint requires the token when one is set", %{conn: conn} do
    Application.put_env(:audio_flow_ui, :mcp_token, "secret")
    on_exit(fn -> Application.delete_env(:audio_flow_ui, :mcp_token) end)

    conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")
    assert conn |> post("/mcp", "{}") |> response(401)

    assert conn
           |> Plug.Conn.put_req_header("authorization", "Bearer wrong")
           |> post("/mcp", "{}")
           |> response(401)

    # With the token, the request reaches Sake, which rejects the empty JSON-RPC body.
    conn =
      conn |> Plug.Conn.put_req_header("authorization", "Bearer secret") |> post("/mcp", "{}")

    assert conn.status in 400..499 and conn.status != 401
  end

  defp assert_eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition was not met")
      true -> Process.sleep(20) && assert_eventually(fun, attempts - 1)
    end
  end
end
