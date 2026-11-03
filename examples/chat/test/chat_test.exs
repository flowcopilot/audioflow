defmodule ChatTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias AudioFlow.Recording.Store
  @endpoint ChatWeb.Endpoint

  test "Linux demo has no model process and runs a complete session" do
    refute Chat.Engine.native?()
    refute Code.ensure_loaded?(EMLX)
    assert Chat.Engine.adapter(:llm) == nil
    assert {:error, :native_profile_required} = Chat.Engine.select(:llm, "qwen3-1.7b")
    assert {:ok, options} = Chat.Setup.options(Chat.Setup.defaults())
    {:ok, session} = AudioFlow.start_session(options)
    on_exit(fn -> AudioFlow.stop_session(session) end)
    {:ok, turn} = AudioFlow.submit(session, %AudioFlow.Text{data: "Hello"})
    assert_receive {AudioFlow, ^session, ^turn, {:text, "You said: Hello."}}
    assert_receive {AudioFlow, ^session, ^turn, {:audio, %AudioFlow.Audio{sample_rate: 16_000}}}
    assert_receive {AudioFlow, ^session, ^turn, {:done, %{duration_us: _}}}
    assert :ok = GenServer.call(session, {:played, turn, 100_000_000})
    assert {:error, _} = GenServer.call(session, {:played, make_ref(), 100_000_000})
    assert :ok = AudioFlow.cancel(session)
  end

  test "provider configuration validates missing environment and preserves speech contract" do
    settings = Map.put(Chat.Setup.defaults(), "mode", "remote")
    assert {:error, missing} = Chat.Setup.options(settings, fn _ -> nil end)
    assert missing =~ "DEEPGRAM_API_KEY"
    assert missing =~ "ELEVENLABS_VOICE_ID"

    for {mode, rate, adapter} <- [
          {"openai", 24_000, AudioFlow.Adapters.OpenAIRealtime},
          {"gemini", 16_000, AudioFlow.Adapters.GeminiLive}
        ] do
      s = Map.put(settings, "mode", mode)
      assert Chat.Setup.rate(s) == rate
      assert {:ok, opts} = Chat.Setup.options(s, fn _ -> "server-value" end)
      assert {^adapter, provider} = opts[:speech_to_speech]
      assert is_function(provider[:api_key], 0)
      refute Keyword.has_key?(opts, :history)
      refute Keyword.has_key?(opts, :stt)
    end
  end

  test "recording redacts split text, omits PCM and deletes the private directory" do
    {:ok, capture} = Chat.Capture.open(self())
    root = capture.store.root
    on_exit(fn -> File.rm_rf(root) end)
    turn = make_ref()

    {:ok, capture, nil} =
      AudioFlow.Recording.consume(capture, {AudioFlow, self(), turn, {:text, "private"}})

    {:ok, capture, nil} =
      AudioFlow.Recording.consume(capture, {AudioFlow, self(), turn, {:text, "@mail.test"}})

    {:ok, capture, nil} =
      AudioFlow.Recording.consume(
        capture,
        {AudioFlow, self(), turn,
         {:audio, %AudioFlow.Audio{data: <<123, 0>>, sample_rate: 16_000}}}
      )

    {:ok, capture, id} =
      AudioFlow.Recording.consume(capture, {AudioFlow, self(), turn, {:done, %{}}})

    assert Chat.Capture.list(capture) == [id]
    {:ok, data} = Store.read(capture.store, id)
    encoded = Jason.encode!(data)
    assert encoded =~ "[REDACTED]"
    refute encoded =~ "private"
    refute encoded =~ "pcm"
    assert :ok = Chat.Capture.close(capture)
    refute File.exists?(root)
  end

  test "actual LiveView controls submit, configure, record, download and delete" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Synthetic demo"
    assert html =~ "No inference"
    view |> element("#configuration") |> render_submit(%{"mode" => "remote"})
    assert render(view) =~ "Missing server environment"
    assert render(view) =~ "Active: demo"
    view |> element("button[phx-click=capture]") |> render_click()
    assert render(view) =~ "Disable and delete recordings"
    render_hook(view, "send", %{"text" => "private-message"})

    assert eventually(fn ->
             render(view) =~ "You said: private-message." and render(view) =~ "Download"
           end)

    [id] = :sys.get_state(view.pid).socket.assigns.artifacts
    render_click(view, "download", %{"id" => id})
    assert_push_event(view, "download", %{data: data})
    assert data =~ "[REDACTED]"
    refute data =~ "private-message"
    render_click(view, "delete", %{"id" => id})
    refute render(view) =~ ">Download<"
    render_click(view, "new_chat")
    assert render(view) =~ "No messages yet"
  end

  test "recording limits and retention never leak unredacted text" do
    {:ok, capture} = Chat.Capture.open(self())
    on_exit(fn -> Chat.Capture.close(capture) end)
    turn = make_ref()
    capture = %{capture | max_bytes: 1}

    assert {:error, :byte_limit, capture} =
             AudioFlow.Recording.consume(capture, {AudioFlow, self(), turn, {:text, "sensitive"}})

    assert {:error, :byte_limit, capture} =
             AudioFlow.Recording.consume(capture, {AudioFlow, self(), turn, {:done, %{}}})

    assert Chat.Capture.list(capture) == []
    for _ <- 1..21, do: Store.write(capture.store, %{safe: "[REDACTED]"})
    # Exact size check.
    # credo:disable-for-next-line ExSlop.Check.Refactor.LengthComparison
    assert length(Chat.Capture.list(capture)) == 20
    expired = %{capture | store: %{capture.store | max_age_ms: 1}}
    Process.sleep(5)
    assert Chat.Capture.list(expired) == []
  end

  test "LiveView forwards real progress, rejects stale tokens and cancels active generation" do
    {:ok, view, _} = live(build_conn(), "/")
    session = :sys.get_state(view.pid).socket.assigns.session
    owner = self()

    slow =
      {AudioFlow.Adapters.Function,
       run: fn text, emit ->
         :ok = emit.(%AudioFlow.Audio{data: :binary.copy(<<0, 0>>, 16_000), sample_rate: 16_000})
         send(owner, {:tts_waiting, self(), text})
         Process.sleep(:infinity)
       end}

    :sys.replace_state(session, fn state -> put_in(state.adapters.tts, slow) end)
    render_hook(view, "send", %{"text" => "cancel me"})
    assert_receive {:tts_waiting, worker, _}, 1000
    assert eventually(fn -> :sys.get_state(view.pid).socket.assigns.rate == 16_000 end)
    assigns = :sys.get_state(view.pid).socket.assigns
    render_hook(view, "played", %{"token" => "stale", "ns" => 100_000_000})
    assert :sys.get_state(view.pid).socket.assigns.played_ms == 0
    render_hook(view, "played", %{"token" => assigns.playback_token, "ns" => 100_000_000})
    assert :sys.get_state(view.pid).socket.assigns.played_ms == 100
    monitor = Process.monitor(worker)
    render_click(view, "stop")
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert_push_event(view, "flush", %{})
    assert render(view) =~ "Stopped"
    assert :sys.get_state(view.pid).socket.assigns.turn == nil
  end

  test "LiveView survives recording overflow and rejects invalid microphone data" do
    {:ok, view, _} = live(build_conn(), "/")
    render_click(view, "capture")

    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.capture.max_bytes, 1)
    end)

    render_hook(view, "send", %{"text" => "private"})
    assert eventually(fn -> render(view) =~ "Recording skipped" end)
    assert :sys.get_state(view.pid).socket.assigns.artifacts == []
    assert eventually(fn -> :sys.get_state(view.pid).socket.assigns.turn == nil end)
    render_hook(view, "recording")
    render_hook(view, "voice_chunk", %{"pcm" => "not base64"})
    render_hook(view, "voice_end", %{"pcm" => ""})
    assert render(view) =~ "Microphone input rejected"
    assert :sys.get_state(view.pid).socket.assigns.turn == nil
  end

  defp eventually(fun, tries \\ 50)
  defp eventually(_, 0), do: false

  defp eventually(fun, tries) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(20)
          eventually(fun, tries - 1)
        )
  end
end
