defmodule Chat.DuplexSetupTest do
  use ExUnit.Case, async: true

  test "CHAT_MODE selects the startup mode; an unknown mode keeps the profile default" do
    assert Chat.Setup.defaults(&%{"CHAT_MODE" => "moshi"}[&1])["mode"] == "moshi"
    assert Chat.Setup.defaults(&%{"CHAT_MODE" => "nope"}[&1])["mode"] == "demo"
    assert Chat.Setup.rate(%{"mode" => "moshi"}) == 24_000
  end

  test "the Moshi endpoint comes only from AUDIOFLOW_MOSHI_ENDPOINT" do
    settings = %{Chat.Setup.defaults(fn _ -> nil end) | "mode" => "moshi"}

    if Code.ensure_loaded?(AudioFlow.Duplex.Moshi) do
      assert {:ok, [duplex: {AudioFlow.Duplex.Moshi, [endpoint: "ws://127.0.0.1:8998/api/chat"]}]} =
               Chat.Setup.options(settings, fn _ -> nil end)

      env = &%{"AUDIOFLOW_MOSHI_ENDPOINT" => "ws://10.0.0.2:9000/api/chat"}[&1]

      assert {:ok, [duplex: {_, [endpoint: "ws://10.0.0.2:9000/api/chat"]}]} =
               Chat.Setup.options(settings, env)

      for endpoint <- ["http://127.0.0.1:8998/api/chat", "ws://user:secret@127.0.0.1/api/chat"] do
        assert {:error, message} =
                 Chat.Setup.options(settings, &%{"AUDIOFLOW_MOSHI_ENDPOINT" => endpoint}[&1])

        assert message =~ "AUDIOFLOW_MOSHI_ENDPOINT"
      end
    else
      assert {:error, "Restart with AUDIOFLOW_MEDIA=1" <> _} =
               Chat.Setup.options(settings, fn _ -> nil end)
    end
  end
end

if Code.ensure_loaded?(AudioFlow.Duplex.Moshi) do
  defmodule Chat.DuplexTest do
    use ExUnit.Case, async: false
    import Phoenix.ConnTest
    import Phoenix.LiveViewTest

    alias Membrane.Ogg.Opus, as: OggOpus
    alias Membrane.Ogg.Page
    alias Membrane.Ogg.Parser
    alias Membrane.Opus.Decoder.Native, as: Decoder
    alias Membrane.Opus.Encoder.Native, as: Encoder

    @endpoint ChatWeb.Endpoint
    @chunk 3_840

    # A local Moshi wire peer: handshake byte, then one 80 ms Ogg Opus page and
    # the scripted text for each 80 ms frame that the client sends. With
    # `answer: false` it reads input and sends no audio.
    defmodule Moshi do
      @behaviour WebSock

      def init({owner, script, answer}) do
        head =
          Page.create_first(1)
          |> Page.append_packet!(OggOpus.create_id_header(1))
          |> Page.finalize(0)

        state = %{
          owner: owner,
          script: script,
          answer: answer,
          buffer: <<>>,
          continued: nil,
          decoder: Decoder.create(24_000, 1),
          encoder: Encoder.create(24_000, 1, 2049, -1000, 3001),
          frames: 0
        }

        send(owner, {:moshi, :connected})
        {:push, [{:binary, <<0>>}, {:binary, <<1>> <> Page.serialize(head)}], state}
      end

      def handle_in({<<1, data::binary>>, opcode: :binary}, state) do
        {packets, continued, rest} = Parser.parse(state.buffer <> data, state.continued)

        pcm =
          for %Parser.Packet{payload: packet} <- packets,
              not String.starts_with?(packet, ["OpusHead", "OpusTags"]),
              into: <<>>,
              do: Decoder.decode_packet(state.decoder, packet)

        frames = div(byte_size(pcm), 3_840)
        if frames > 0, do: send(state.owner, {:moshi, :input_frames, frames})

        replies =
          Enum.flat_map(state.frames..(state.frames + frames - 1)//1, fn index ->
            [{:binary, <<1>> <> output(state, index)}] ++
              for text <- List.wrap(state.script[index]), do: {:binary, <<2>> <> text}
          end)

        {:push, if(state.answer, do: replies, else: []),
         %{state | buffer: rest, continued: continued, frames: state.frames + frames}}
      end

      def handle_info(_message, state), do: {:ok, state}

      defp output(state, index) do
        page = %Page{bos: false, bitstream_serial_number: 1, page_sequence_number: index + 1}

        for _ <- 1..4, reduce: page do
          page ->
            {:ok, packet} = Encoder.encode_packet(state.encoder, :binary.copy(<<0, 0>>, 480), 480)
            Page.append_packet!(page, packet)
        end
        |> Page.finalize((index + 1) * 3_840)
        |> Page.serialize()
      end
    end

    defmodule Server do
      def init(options), do: options

      def call(conn, options),
        do: conn |> WebSockAdapter.upgrade(Moshi, options, []) |> Plug.Conn.halt()
    end

    setup do
      for name <- ["CHAT_MODE", "AUDIOFLOW_MOSHI_ENDPOINT"] do
        original = System.get_env(name)

        on_exit(fn ->
          if original, do: System.put_env(name, original), else: System.delete_env(name)
        end)
      end

      System.put_env("CHAT_MODE", "moshi")
      :ok
    end

    defp moshi(script, answer \\ true) do
      server =
        start_supervised!(
          Supervisor.child_spec(
            {Bandit,
             plug: {Server, {self(), script, answer}},
             port: 0,
             ip: {127, 0, 0, 1},
             startup_log: false},
            id: make_ref()
          )
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      System.put_env("AUDIOFLOW_MOSHI_ENDPOINT", "ws://127.0.0.1:#{port}/api/chat")
    end

    defp chunk(byte \\ 1), do: Base.encode64(:binary.copy(<<byte, 0>>, div(@chunk, 2)))
    defp call(view), do: :sys.get_state(view.pid).socket.assigns.call

    defp connect(view) do
      # A browser-supplied endpoint is ignored; the server environment wins.
      render_hook(view, "call_start", %{"endpoint" => "ws://127.0.0.1:1/api/chat"})
      assert_reply(view, %{ok: true, generation: generation})
      assert_receive {:moshi, :connected}, 2_000
      assert_push_event(view, "call_ready", %{generation: ^generation}, 2_000)
      generation
    end

    test "CHAT_MODE=moshi opens the duplex controls instead of turn-based input" do
      {:ok, view, _} = live(build_conn(), "/")
      html = render(view)
      assert html =~ "Start conversation"
      assert html =~ "Not connected"
      assert html =~ "Active: moshi"
      refute has_element?(view, "#prompt")
      refute has_element?(view, "#recorder")
      assert has_element?(view, "button[phx-click=capture][disabled]")
      assert has_element?(view, "button[data-call=stop][disabled]")
      assert :sys.get_state(view.pid).socket.assigns.session == nil
    end

    test "microphone input and model output flow at the same time until stop" do
      moshi(%{0 => " Hi", 1 => " there."})
      {:ok, view, _} = live(build_conn(), "/")
      generation = connect(view)
      assert render(view) =~ "Live: microphone and playback on"
      assert has_element?(view, "button[data-call=start][disabled]")

      render_hook(view, "call_audio", %{"generation" => generation, "pcm" => chunk()})
      assert_reply(view, %{ok: true})
      assert_receive {:moshi, :input_frames, 1}, 2_000
      assert_push_event(view, "call_play", %{generation: ^generation, rate: 24_000, pcm: pcm})
      assert byte_size(Base.decode64!(pcm)) == @chunk

      # Model audio arrived; the next input is still accepted and answered.
      render_hook(view, "call_audio", %{"generation" => generation, "pcm" => chunk()})
      assert_reply(view, %{ok: true})
      assert_receive {:moshi, :input_frames, 1}, 2_000
      assert_push_event(view, "call_play", %{generation: ^generation})
      assert eventually(fn -> render(view) =~ "Hi there." end)

      %{pid: duplex} = call(view)
      monitor = Process.monitor(duplex)
      render_hook(view, "call_stop", %{"generation" => generation})
      assert_receive {:DOWN, ^monitor, :process, ^duplex, :normal}
      assert_push_event(view, "call_stopped", %{generation: ^generation})
      assert render(view) =~ "Not connected"
      assert render(view) =~ "Hi there."

      render_hook(view, "call_audio", %{"generation" => generation, "pcm" => chunk()})
      assert_reply(view, %{ok: false, error: "stale"})
    end

    test "input chunks are bounded, generation-checked and rejected before the handshake" do
      moshi(%{})
      {:ok, view, _} = live(build_conn(), "/")

      render_hook(view, "call_audio", %{"generation" => 1, "pcm" => chunk()})
      assert_reply(view, %{ok: false, error: "stale"})

      generation = connect(view)

      for pcm <- [Base.encode64(<<0, 0>>), Base.encode64(:binary.copy(<<0>>, 4 * @chunk)), "%%"] do
        render_hook(view, "call_audio", %{"generation" => generation, "pcm" => pcm})
        assert_reply(view, %{ok: false, error: "invalid_chunk"})
      end

      render_hook(view, "call_audio", %{"generation" => generation + 1, "pcm" => chunk()})
      assert_reply(view, %{ok: false, error: "stale"})
      assert call(view).generation == generation
    end

    test "input that the model has not answered for 2 s is refused, and the call stays open" do
      moshi(%{}, false)
      {:ok, view, _} = live(build_conn(), "/")
      generation = connect(view)

      for _ <- 1..25 do
        render_hook(view, "call_audio", %{"generation" => generation, "pcm" => chunk()})
        assert_reply(view, %{ok: true})
      end

      render_hook(view, "call_audio", %{"generation" => generation, "pcm" => chunk()})
      assert_reply(view, %{ok: false, error: "overloaded"})
      assert render(view) =~ "Live: microphone and playback on"
    end

    test "settings and a second conversation are refused while one is active" do
      moshi(%{})
      {:ok, view, _} = live(build_conn(), "/")
      connect(view)

      render_hook(view, "call_start", %{})
      assert_reply(view, %{ok: false, error: "A conversation is already active."})
      view |> element("#configuration") |> render_submit(%{"mode" => "demo"})
      assert render(view) =~ "Stop the current turn, recording or conversation"
      assert render(view) =~ "Active: moshi"
    end

    test "microphone denial and an unreachable model stop the conversation with an error" do
      moshi(%{})
      {:ok, view, _} = live(build_conn(), "/")
      generation = connect(view)
      %{pid: duplex} = call(view)
      monitor = Process.monitor(duplex)
      render_hook(view, "call_failed", %{"message" => "Permission denied"})
      assert_receive {:DOWN, ^monitor, :process, ^duplex, :normal}
      assert_push_event(view, "call_stopped", %{generation: ^generation})
      assert has_element?(view, "[role=alert]", "Microphone error: Permission denied")

      {:ok, closed} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(closed)
      :gen_tcp.close(closed)
      System.put_env("AUDIOFLOW_MOSHI_ENDPOINT", "ws://127.0.0.1:#{port}/api/chat")
      render_hook(view, "call_start", %{})
      assert_reply(view, %{ok: true, generation: failed})
      assert_push_event(view, "call_stopped", %{generation: ^failed}, 2_000)
      assert has_element?(view, "[role=alert]", "Conversation error: connect_failed")
      assert render(view) =~ "Stopped by an error"
      assert has_element?(view, "button[data-call=start]:not([disabled])")
    end

    test "model text after a pause starts a new message" do
      moshi(%{0 => " One.", 30 => " Two."})
      {:ok, view, _} = live(build_conn(), "/")
      generation = connect(view)

      push = fn ->
        render_hook(view, "call_audio", %{"generation" => generation, "pcm" => chunk()})
      end

      push.()
      assert eventually(fn -> render(view) =~ "One." end)
      Process.sleep(1_600)

      for _ <- 1..30 do
        push.()
        assert_receive {:moshi, :input_frames, 1}, 2_000
      end

      assert eventually(fn -> render(view) =~ "Two." end)

      texts =
        for %{role: "assistant", text: text} <- :sys.get_state(view.pid).socket.assigns.messages,
            do: text

      assert texts == ["One.", "Two."]
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
end
