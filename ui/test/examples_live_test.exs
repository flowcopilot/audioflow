defmodule AudioFlowUIWeb.ExamplesLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint AudioFlowUIWeb.Endpoint

  setup do
    AudioFlowUI.TestGraphs.clear()
    on_exit(&AudioFlowUI.TestGraphs.clear/0)
    %{conn: build_conn()}
  end

  test "examples execute workflow and evaluation and link standalone transports", %{conn: conn} do
    {:ok, view, html} = live(conn, "/examples")
    assert html =~ "examples/rtvi-client"
    assert html =~ "examples/telephony-loopback.exs"
    view |> element("#workflow") |> render_click()
    eventually(fn -> render(view) =~ "state_after_failure" end)
    assert render(view) =~ "billing"

    view
    |> form("#evaluation", %{"graph" => "synthetic", "script" => "Hello => You said: Hello."})
    |> render_submit()

    eventually(fn -> render(view) =~ "passed: true" end)
  end

  test "starter creates an editable graph and surfaces actual missing prerequisites", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/examples")
    view |> element("[phx-value-kind=rag]") |> render_click()
    assert_redirect(view, "/graphs/rag")
    {:ok, graph, html} = live(conn, "/graphs/rag")
    assert html =~ "retrieval profile is not configured"
    assert has_element?(graph, "#canvas-node-docs")
  end

  test "PCM upload submits a committed utterance", %{conn: conn} do
    {:ok, _} = AudioFlowUI.Graphs.put(AudioFlowUI.TestGraphs.voice())
    {:ok, view, _} = live(conn, "/graphs/voice")

    upload =
      file_input(view, "#run-audio", :pcm, [
        %{
          name: "utterance.pcm",
          content: <<0, 0, 1, 0>>,
          type: "application/octet-stream"
        }
      ])

    render_upload(upload, "utterance.pcm")
    view |> form("#run-audio", %{"rate" => "16000"}) |> render_submit()
    eventually(fn -> render(view) =~ "You said: Hello." end)
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("result did not arrive")

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
