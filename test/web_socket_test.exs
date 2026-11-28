defmodule AudioFlow.WebSocketTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Test.WebSocketClient, as: Client
  alias AudioFlow.Transport.Connection

  defmodule Endpoint do
    @behaviour Plug
    def init(options), do: options

    def call(conn, options),
      do: conn |> WebSockAdapter.upgrade(AudioFlow.WebSocket, options, []) |> Plug.Conn.halt()
  end

  defp connect(options \\ []) do
    options = Keyword.put_new(options, :session, Demo.options())

    server =
      start_supervised!(
        {Bandit, plug: {Endpoint, options}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    socket = Client.connect(port)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp function(fun), do: {AudioFlow.Adapters.Function, [run: fun]}
  defp silence(samples), do: :binary.copy(<<0, 0>>, samples)

  defp ready(socket) do
    assert {:json, %{"type" => "ready"} = ready} = Client.recv(socket)
    ready
  end

  defp assert_json(socket, expected) do
    assert {:json, message} = Client.recv(socket)
    assert Map.take(message, Map.keys(expected)) == expected
    message
  end

  test "committed PCM produces ordered events, output format, and PCM frames" do
    socket = connect()

    assert %{
             "mode" => "commit",
             "input" => %{"encoding" => "pcm_s16le", "sample_rate" => 16_000, "channels" => 1}
           } = ready(socket)

    Client.send_binary(socket, silence(800))
    Client.send_binary(socket, silence(800))
    Client.send_json(socket, %{type: "commit"})

    assert_json(socket, %{"type" => "turn_started", "turn" => 1})
    assert_json(socket, %{"type" => "transcript", "turn" => 1, "text" => "Hello"})
    assert_json(socket, %{"type" => "text", "turn" => 1, "text" => "You said: Hello."})
    assert_json(socket, %{"type" => "output_format", "sample_rate" => 16_000})
    assert {:binary, pcm} = Client.recv(socket)
    assert byte_size(pcm) == 3200
    done = assert_json(socket, %{"type" => "done", "turn" => 1})
    assert done["metrics"]["events"] == 3
  end

  test "a transcription session sends partials and timed transcripts" do
    stt =
      function(fn _, emit ->
        emit.({:partial, "hel"})

        emit.(%AudioFlow.Transcript.Segment{
          text: "hello",
          start_ms: 0,
          end_ms: 400,
          words: [%{word: "hello", start_ms: 0, end_ms: 400}]
        })
      end)

    socket = connect(session: [stt: stt])
    ready(socket)
    Client.send_binary(socket, silence(800))
    Client.send_json(socket, %{type: "commit"})

    assert_json(socket, %{"type" => "turn_started", "turn" => 1})
    assert_json(socket, %{"type" => "partial_transcript", "turn" => 1, "text" => "hel"})

    assert_json(socket, %{
      "type" => "transcript",
      "text" => "hello",
      "start_ms" => 0,
      "end_ms" => 400,
      "words" => [%{"word" => "hello", "start_ms" => 0, "end_ms" => 400}]
    })

    assert_json(socket, %{"type" => "done", "turn" => 1})
  end

  test "a typed message skips transcription and the format is sent once" do
    socket = connect()
    ready(socket)

    for turn <- 1..2 do
      Client.send_json(socket, %{type: "text", text: "Hi"})
      assert_json(socket, %{"type" => "turn_started", "turn" => turn})
      assert_json(socket, %{"type" => "text", "text" => "You said: Hi."})
      if turn == 1, do: assert_json(socket, %{"type" => "output_format"})
      assert {:binary, _} = Client.recv(socket)
      assert_json(socket, %{"type" => "done", "turn" => turn})
    end
  end

  test "invalid client messages and busy input return errors without closing" do
    owner = self()

    socket =
      connect(
        session:
          Keyword.put(
            Demo.options(),
            :llm,
            function(fn _, _ ->
              send(owner, :llm_started)
              Process.sleep(:infinity)
            end)
          ),
        max_chunk_bytes: 4
      )

    ready(socket)
    Client.send_binary(socket, <<0, 0, 0>>)
    assert_json(socket, %{"type" => "error", "reason" => "invalid_audio"})
    Client.send_binary(socket, silence(3))
    assert_json(socket, %{"type" => "error", "reason" => "chunk_too_large"})
    Client.send_json(socket, %{type: "commit"})
    assert_json(socket, %{"type" => "error", "reason" => "empty_input"})
    :ok = :gen_tcp.send(socket, <<0x81, 0x80, 0, 0, 0, 0>>)
    assert_json(socket, %{"type" => "error", "reason" => "invalid_message"})
    Client.send_json(socket, %{type: "dance"})
    assert_json(socket, %{"type" => "error", "reason" => "invalid_message"})

    Client.send_json(socket, %{type: "text", text: "one"})
    assert_json(socket, %{"type" => "turn_started", "turn" => 1})
    assert_receive :llm_started
    Client.send_json(socket, %{type: "text", text: "two"})
    assert_json(socket, %{"type" => "error", "reason" => "busy"})
    Client.send_json(socket, %{type: "clear_history"})
    assert_json(socket, %{"type" => "error", "reason" => "busy"})
  end

  test "cancel flushes playback and drops output from the old turn" do
    owner = self()

    tts =
      function(fn _, emit ->
        emit.(%AudioFlow.Audio{data: silence(10), sample_rate: 24_000})
        send(owner, {:tts_waiting, self()})

        receive do
          :continue -> emit.(%AudioFlow.Audio{data: silence(10), sample_rate: 24_000})
        end
      end)

    socket = connect(session: Keyword.put(Demo.options(), :tts, tts))
    ready(socket)
    Client.send_json(socket, %{type: "text", text: "Hi"})
    assert_json(socket, %{"type" => "turn_started", "turn" => 1})
    assert_json(socket, %{"type" => "text"})
    assert_json(socket, %{"type" => "output_format", "sample_rate" => 24_000})
    assert {:binary, _} = Client.recv(socket)
    assert_receive {:tts_waiting, task}
    ref = Process.monitor(task)

    Client.send_json(socket, %{type: "cancel"})
    assert_json(socket, %{"type" => "cancelled", "turn" => 1})
    assert_json(socket, %{"type" => "flush"})
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    assert {:error, :timeout} = Client.recv(socket, 100)

    Client.send_json(socket, %{type: "clear_history"})
    assert_json(socket, %{"type" => "history_cleared"})
  end

  test "detected speech interrupts the reply and an endpoint submits the utterance" do
    owner = self()

    llm =
      function(fn prompt, emit ->
        send(owner, {:llm, prompt})
        if prompt == "Hello", do: emit.("Reply."), else: Process.sleep(:infinity)
      end)

    socket =
      connect(
        session: Keyword.put(Demo.options(), :llm, llm),
        vad: {AudioFlow.Test.AlwaysSpeechDetector, []}
      )

    assert %{"mode" => "vad"} = ready(socket)
    Client.send_json(socket, %{type: "text", text: "slow"})
    assert_json(socket, %{"type" => "turn_started", "turn" => 1})
    assert_receive {:llm, "slow"}

    # 96 ms of speech at 16 kHz confirms speech after three 512-sample frames.
    Client.send_binary(socket, silence(1536))
    assert_json(socket, %{"type" => "speech_started"})
    assert_json(socket, %{"type" => "cancelled", "turn" => 1})
    assert_json(socket, %{"type" => "flush"})

    Client.send_json(socket, %{type: "commit"})
    assert_json(socket, %{"type" => "turn_started", "turn" => 2})
    assert_json(socket, %{"type" => "transcript", "turn" => 2})
    assert_receive {:llm, "Hello"}
  end

  @tag :capture_log
  test "an adapter exception reaches the client only as a stable code" do
    llm = function(fn _, _ -> raise KeyError, key: :api_key, term: [api_key: "sk-secret-123"] end)
    socket = connect(session: Keyword.put(Demo.options(), :llm, llm))
    ready(socket)
    Client.send_json(socket, %{type: "text", text: "Hi"})
    assert_json(socket, %{"type" => "turn_started", "turn" => 1})
    assert_json(socket, %{"type" => "flush"})

    assert %{"reason" => "internal_error"} =
             error = assert_json(socket, %{"type" => "error", "turn" => 1})

    refute JSON.encode!(error) =~ "sk-secret"
  end

  test "reason codes are fixed strings for known shapes" do
    code = &Connection.reason_code/1
    assert code.(:busy) == "busy"
    assert code.({:output, :closed}) == "output_failed"
    assert code.({:task_exit, {:badarg, []}}) == "turn_crashed"
    assert code.({:session_stop, :shutdown}) == "session_stopped"
    assert code.({:exception, "secret"}) == "internal_error"
    assert code.(%{token: "secret"}) == "internal_error"
  end

  @tag :capture_log
  test "a rejected output chunk fails the turn and keeps the connection open" do
    socket = connect(output_check: fn _ -> {:error, :blocked} end)
    ready(socket)
    Client.send_json(socket, %{type: "text", text: "Hi"})
    assert_json(socket, %{"type" => "turn_started", "turn" => 1})
    assert_json(socket, %{"type" => "text"})
    assert_json(socket, %{"type" => "flush"})
    assert_json(socket, %{"type" => "error", "turn" => 1, "reason" => "output_failed"})
    Client.send_json(socket, %{type: "clear_history"})
    assert_json(socket, %{"type" => "history_cleared"})
  end

  @tag :capture_log
  test "an unresponsive or dead session becomes an error event" do
    {:push, _ready, state} = AudioFlow.WebSocket.init(session: Demo.options())
    on_exit(fn -> AudioFlow.WebSocket.terminate(:normal, state) end)
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    state = %{state | session: dead}

    for message <- [%{"type" => "text", "text" => "Hi"}, %{"type" => "cancel"}] do
      assert {:push, [{:text, json}], _} =
               AudioFlow.WebSocket.handle_in({JSON.encode!(message), opcode: :text}, state)

      assert %{"type" => "error", "reason" => "session_unavailable"} = JSON.decode!(json)
    end
  end

  test "a cancel that races a finished turn reports the turn as done" do
    {:push, _ready, state} = AudioFlow.WebSocket.init(session: Demo.options())
    on_exit(fn -> AudioFlow.WebSocket.terminate(:normal, state) end)
    ref = make_ref()
    session = state.session
    state = %{state | turn: {ref, 7}}
    send(self(), {AudioFlow, session, ref, {:text, "Hi"}})
    send(self(), {AudioFlow, session, ref, {:done, %{events: 1}}})

    assert {:push, [{:text, json}], state} =
             AudioFlow.WebSocket.handle_in({~s({"type":"cancel"}), opcode: :text}, state)

    assert %{"type" => "done", "turn" => 7} = JSON.decode!(json)
    assert state.turn == nil
  end

  test "a cancel of a running turn reports it as cancelled" do
    {:push, _ready, state} = AudioFlow.WebSocket.init(session: Demo.options())
    on_exit(fn -> AudioFlow.WebSocket.terminate(:normal, state) end)
    {:ok, ref} = AudioFlow.submit(state.session, %AudioFlow.Text{data: "Hi"})
    state = %{state | turn: {ref, 3}}

    assert {:push, [{:text, json}], _} =
             AudioFlow.WebSocket.handle_in({~s({"type":"cancel"}), opcode: :text}, state)

    assert %{"type" => "cancelled", "turn" => 3} = JSON.decode!(json)
  end

  test "closing the connection stops its session" do
    owner = self()

    llm =
      function(fn _, _ ->
        send(owner, {:session, hd(Process.get(:"$callers"))})
        Process.sleep(:infinity)
      end)

    socket = connect(session: Keyword.put(Demo.options(), :llm, llm))
    ready(socket)
    Client.send_json(socket, %{type: "text", text: "Hi"})
    assert_receive {:session, session}
    ref = Process.monitor(session)
    Client.close(socket)
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  test "the detector rate must match the input rate" do
    assert_raise ArgumentError, ~r/detector rate 16000/, fn ->
      AudioFlow.WebSocket.init(
        session: Demo.options(),
        vad: {AudioFlow.Test.AlwaysSpeechDetector, []},
        sample_rate: 8000
      )
    end
  end
end
