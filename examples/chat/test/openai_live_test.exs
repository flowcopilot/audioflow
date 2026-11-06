defmodule Chat.OpenAILiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint ChatWeb.Endpoint
  @chunk 3_840

  # A local peer with the OpenAI Realtime GA event framing. It reports each
  # connection and client event to the test and pushes the events the test
  # sends. It never acts on its own.
  defmodule Peer do
    @behaviour WebSock

    def init(owner) do
      send(owner, {:peer, self()})
      {:ok, owner}
    end

    def handle_in({data, opcode: :text}, owner) do
      send(owner, {:client, JSON.decode!(data)})
      {:ok, owner}
    end

    def handle_info({:events, events}, owner),
      do: {:push, Enum.map(events, &{:text, JSON.encode!(&1)}), owner}

    def terminate(_reason, owner) do
      send(owner, :peer_closed)
      :ok
    end
  end

  defmodule Server do
    def init(owner), do: owner

    def call(conn, owner) do
      send(owner, {:upgrade, conn.query_string})
      conn |> WebSockAdapter.upgrade(Peer, owner, []) |> Plug.Conn.halt()
    end
  end

  setup do
    names = ["CHAT_MODE", "OPENAI_API_KEY", "OPENAI_REALTIME_MODEL", "OPENAI_REALTIME_ENDPOINT"]
    original = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- original,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    System.put_env(%{
      "CHAT_MODE" => "openai",
      "OPENAI_API_KEY" => "fixture-key",
      "OPENAI_REALTIME_MODEL" => "fixture-model"
    })

    :ok
  end

  # The server reads the provider endpoint only from its environment.
  defp openai_peer do
    server =
      start_supervised!(
        {Bandit, plug: {Server, self()}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    System.put_env("OPENAI_REALTIME_ENDPOINT", "ws://127.0.0.1:#{port}/v1/realtime")
  end

  defp connect(view) do
    render_hook(view, "call_start", %{"endpoint" => "ws://127.0.0.1:1/ignored"})
    assert_reply(view, %{ok: true, generation: generation})
    assert_receive {:upgrade, "model=fixture-model"}, 2_000
    assert_receive {:peer, peer}
    send(peer, {:events, [%{type: "session.created", session: %{}}]})
    assert_receive {:client, %{"type" => "session.update", "session" => session}}, 2_000
    assert render(view) =~ "Connecting…"
    send(peer, {:events, [%{type: "session.updated", session: session}]})
    assert_push_event(view, "call_ready", %{generation: ^generation}, 2_000)
    {generation, peer, session}
  end

  defp audio(view, generation) do
    pcm = Base.encode64(:binary.copy(<<0>>, @chunk))
    render_hook(view, "call_audio", %{"generation" => generation, "pcm" => pcm})
  end

  defp utterance(peer, user, transcript, response, item, text) do
    send(
      peer,
      {:events,
       [
         %{type: "input_audio_buffer.speech_started", item_id: user, audio_start_ms: 0},
         %{type: "input_audio_buffer.speech_stopped", item_id: user, audio_end_ms: 800},
         %{type: "response.created", response: %{id: response}},
         %{
           type: "response.output_audio.delta",
           response_id: response,
           item_id: item,
           content_index: 0,
           delta: Base.encode64(:binary.copy(<<0>>, 4_800))
         },
         %{type: "response.output_audio_transcript.delta", response_id: response, delta: text},
         %{
           type: "conversation.item.input_audio_transcription.completed",
           item_id: user,
           transcript: transcript
         }
       ]}
    )
  end

  defp messages(view) do
    for %{role: role, text: text} <- :sys.get_state(view.pid).socket.assigns.messages,
        do: {role, text}
  end

  test "OpenAI mode opens the always-on controls with the voice choice" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "OpenAI live conversation"
    assert html =~ "Start conversation"
    assert has_element?(view, "select[name=voice]")
    assert has_element?(view, "button[data-call=stop][disabled]")
    refute has_element?(view, "#prompt")
    refute has_element?(view, "#recorder")
    refute view |> element("#duplex") |> render() =~ "Moshi"
    assert :sys.get_state(view.pid).socket.assigns.session == nil
  end

  test "one connection hears several utterances while the microphone streams" do
    openai_peer()
    {:ok, view, _} = live(build_conn(), "/")
    view |> element("#configuration") |> render_submit(%{"mode" => "openai", "voice" => "cedar"})
    {generation, peer, session} = connect(view)
    assert session["audio"]["output"]["voice"] == "cedar"
    assert render(view) =~ "Live · microphone on"

    for _ <- 1..10 do
      audio(view, generation)
      assert_reply(view, %{ok: true})
      assert_receive {:client, %{"type" => "input_audio_buffer.append"}}
    end

    utterance(peer, "user_1", "Hello there", "resp_1", "item_1", "Hi! How can I help?")
    assert_push_event(view, "call_flush", %{generation: ^generation}, 2_000)

    assert_push_event(view, "call_play", %{generation: ^generation, output: "item_1", pcm: pcm})
    assert byte_size(Base.decode64!(pcm)) == 4_800

    # The microphone keeps streaming while reply audio plays.
    audio(view, generation)
    assert_reply(view, %{ok: true})

    send(
      peer,
      {:events,
       [%{type: "response.done", response: %{id: "resp_1", status: "completed", output: []}}]}
    )

    assert eventually(fn ->
             messages(view) == [{"user", "Hello there"}, {"assistant", "Hi! How can I help?"}]
           end)

    # The second utterance interrupts the reply; the browser reports what played.
    utterance(peer, "user_2", "Stop, another question", "resp_2", "item_2", "Sure.")
    assert_push_event(view, "call_flush", %{generation: ^generation}, 2_000)

    render_hook(view, "call_played", %{
      "generation" => generation,
      "output" => "item_1",
      "ms" => 40
    })

    assert_receive {:client,
                    %{
                      "type" => "conversation.item.truncate",
                      "item_id" => "item_1",
                      "audio_end_ms" => 40
                    }},
                   2_000

    assert eventually(fn ->
             messages(view) == [
               {"user", "Hello there"},
               {"assistant", "Hi! How can I help?"},
               {"user", "Stop, another question"},
               {"assistant", "Sure."}
             ]
           end)

    # Both utterances used the same provider connection; none was committed by the client.
    refute_received {:peer, _}
    refute_received {:client, %{"type" => "input_audio_buffer.commit"}}
    refute_received {:client, %{"type" => "response.create"}}

    render_hook(view, "call_stop", %{"generation" => generation})
    assert_push_event(view, "call_stopped", %{generation: ^generation})
    assert_receive :peer_closed, 2_000
    assert render(view) =~ "Not connected"
  end

  test "a provider error stops the call with its code and a new call starts fresh" do
    openai_peer()
    {:ok, view, _} = live(build_conn(), "/")
    {generation, peer, _} = connect(view)

    send(
      peer,
      {:events,
       [%{type: "error", error: %{type: "server_error", code: "boom", message: "provider-message-text"}}]}
    )

    assert_push_event(view, "call_stopped", %{generation: ^generation}, 2_000)
    assert has_element?(view, "[role=alert]", "Conversation error: provider error boom")
    refute render(view) =~ "provider-message-text"
    assert_receive :peer_closed, 2_000

    {next, _peer, _} = connect(view)
    assert next == generation + 1
  end

  defp eventually(fun, tries \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, tries - 1)
    end
  end
end
