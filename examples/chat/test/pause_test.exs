defmodule Chat.PauseTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint ChatWeb.Endpoint

  test "transport delivers ordered commands with the original turn and PCM" do
    turn = make_ref()
    id = make_ref()
    key = {self(), turn}
    audio = %AudioFlow.Audio{data: <<1, 0>>, sample_rate: 16_000}

    for result <- [
          Chat.Output.start_turn(self(), key),
          Chat.Output.push(self(), key, audio),
          Chat.Output.pause(self(), key, id),
          Chat.Output.resume(self(), key, id),
          Chat.Output.flush(self(), key)
        ],
        do: assert(result == :ok)

    assert_receive {Chat.Output, {:start, ^turn, token}}
    assert_receive {Chat.Output, {:pcm, ^turn, ^token, ^audio}}
    assert_receive {Chat.Output, {:control, ^turn, ^id, :pause}}
    assert_receive {Chat.Output, {:control, ^turn, ^id, :resume}}
    assert_receive {Chat.Output, {:flush, ^turn}}
  end

  test "LiveView pause and resume require matching endpoint acks; false candidate keeps history" do
    {:ok, view, _} = live(build_conn(), "/")
    render_hook(view, "send", %{"text" => "continuity"})
    assert eventually(fn -> assigns(view).turn == nil and assigns(view).playback_turn != nil end)
    session = assigns(view).session
    history = :sys.get_state(session).history
    render_click(view, "pause")
    assert_push_event(view, "output_control", %{action: :pause, token: token, id: id})
    refute assigns(view).paused

    render_hook(view, "output_ack", %{
      "action" => "pause",
      "token" => "old",
      "id" => id,
      "ns" => 0
    })

    refute assigns(view).paused

    render_hook(view, "output_ack", %{
      "action" => "pause",
      "token" => token,
      "id" => id,
      "ns" => 0
    })

    assert assigns(view).paused
    render_click(view, "resume")
    assert_push_event(view, "output_control", %{action: :resume, token: ^token, id: ^id})
    assert assigns(view).paused

    render_hook(view, "output_ack", %{
      "action" => "resume",
      "token" => token,
      "id" => id,
      "ns" => 0
    })

    refute assigns(view).paused
    assert :sys.get_state(session).candidate == nil
    assert :sys.get_state(session).history == history

    render_hook(view, "output_ack", %{
      "action" => "pause",
      "token" => token,
      "id" => id,
      "ns" => 0
    })

    refute assigns(view).paused
    render_click(view, "pause")
    assert_push_event(view, "output_control", %{action: :pause})
    render_click(view, "stop")
    assert eventually(fn -> assigns(view).candidate == nil end)

    render_hook(view, "output_ack", %{
      "action" => "pause",
      "token" => token,
      "id" => id,
      "ns" => 0
    })

    refute assigns(view).paused
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
  defp eventually(fun, n \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, n) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(5)
          eventually(fun, n - 1)
        )
  end
end
