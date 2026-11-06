defmodule AudioFlow.WebSocketTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Test.WebSocketClient, as: Client

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
