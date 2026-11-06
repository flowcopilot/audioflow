defmodule AudioFlow.NetworkProtocolTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Test.WebSocketClient, as: Client

  defmodule Endpoint do
    @behaviour Plug
    def init(options), do: options

    def call(conn, {handler, options}),
      do: conn |> WebSockAdapter.upgrade(handler, options, []) |> Plug.Conn.halt()
  end

  defp connect(handler, options) do
    server =
      start_supervised!(
        {Bandit,
         plug: {Endpoint, {handler, options}}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    socket = Client.connect(port)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp start_message(:twilio),
    do: %{
      event: "start",
      streamSid: "stream-1",
      start: %{
        streamSid: "stream-1",
        mediaFormat: %{encoding: "audio/x-mulaw", sampleRate: 8000, channels: 1}
      }
    }

  defp start_message(:telnyx),
    do: %{
      event: "start",
      stream_id: "stream-1",
      start: %{media_format: %{encoding: "PCMU", sample_rate: 8000, channels: 1}}
    }

  defp stream_key(:twilio), do: :streamSid
  defp stream_key(:telnyx), do: :stream_id

  for provider <- [:twilio, :telnyx] do
    @provider provider
    test "#{provider} PCMU input reaches session and returns provider media; stop closes" do
      owner = self()

      stt =
        {AudioFlow.Adapters.Function,
         [
           run: fn audio, emit ->
             send(owner, {:input, audio})
             emit.("hello")
           end
         ]}

      socket =
        connect(AudioFlow.Telephony.WebSocket,
          provider: @provider,
          session: Keyword.put(Demo.options(), :stt, stt),
          vad: {AudioFlow.Test.AlwaysSpeechDetector, []},
          endpoint_options: [pre_roll_ms: 0, max_utterance_ms: 96]
        )

      Client.send_json(socket, %{event: "connected"})
      Client.send_json(socket, start_message(@provider))
      assert {:error, :timeout} = Client.recv(socket, 30)

      media = %{
        event: "media",
        media: %{track: "inbound", chunk: "1", payload: Base.encode64(:binary.copy(<<255>>, 768))}
      }

      Client.send_json(socket, Map.put(media, stream_key(@provider), "stream-1"))
      assert_receive {:input, %AudioFlow.Audio{sample_rate: 16_000, data: data}}
      assert byte_size(data) == 3072

      for _ <- 1..6 do
        assert {:json, %{"event" => "media", "media" => %{"payload" => payload}} = frame} =
                 Client.recv(socket)

        assert byte_size(Base.decode64!(payload)) == 160
        if @provider == :twilio, do: assert(frame["streamSid"] == "stream-1")
        if @provider == :telnyx, do: refute(Map.has_key?(frame, "streamSid"))
      end

      Client.send_json(socket, Map.put(%{event: "stop"}, stream_key(@provider), "stream-1"))
      assert {:close, _} = Client.recv(socket)
    end

    test "#{provider} rejects media before start" do
      options = [
        provider: @provider,
        session: Demo.options(),
        vad: {AudioFlow.Test.AlwaysSpeechDetector, []}
      ]

      socket = connect(AudioFlow.Telephony.WebSocket, options)
      Client.send_json(socket, %{event: "media"})
      assert {:close, <<1008::16, _::binary>>} = Client.recv(socket)
    end
  end

  test "RTVI 2 control handshake, immediate send-text and documented text/audio events" do
    socket = connect(AudioFlow.RTVI.WebSocket, session: Demo.options())

    ready = %{
      label: "rtvi-ai",
      id: "ready-1",
      type: "client-ready",
      data: %{version: "2.0.0", about: %{library: "fixture-client"}}
    }

    Client.send_json(socket, ready)

    assert {:json,
            %{
              "id" => "ready-1",
              "label" => "rtvi-ai",
              "type" => "bot-ready",
              "data" => %{"version" => "2.0.0"}
            }} = Client.recv(socket)

    Client.send_json(socket, %{
      label: "rtvi-ai",
      id: "text-1",
      type: "send-text",
      data: %{content: "Hi"}
    })

    assert {:json,
            %{
              "label" => "rtvi-ai",
              "type" => "llm-raw-text",
              "data" => %{"text" => "You said: Hi."}
            }} = Client.recv(socket)

    assert {:json,
            %{
              "type" => "bot-tts-audio",
              "data" => %{"audio" => audio, "sample_rate" => 16_000, "num_channels" => 1}
            }} = Client.recv(socket)

    assert byte_size(Base.decode64!(audio)) == 3200
    Client.send_json(socket, %{label: "rtvi-ai", id: "bad", type: "update-config", data: %{}})
    assert {:json, %{"type" => "error-response", "id" => "bad"}} = Client.recv(socket)
    Client.send_json(socket, put_in(ready.data.version, "1.0.0"))
    assert {:json, %{"type" => "error-response", "id" => "ready-1"}} = Client.recv(socket)
  end

  test "telephony rejects wrong streams, unsupported formats, invalid payloads and unordered chunks" do
    handler = AudioFlow.Telephony.WebSocket

    options = [
      provider: :twilio,
      session: Demo.options(),
      vad: {AudioFlow.Test.AlwaysSpeechDetector, []}
    ]

    frame = fn message -> {JSON.encode!(message), opcode: :text} end
    {:ok, initial} = handler.init(options)
    invalid = put_in(start_message(:twilio).start.mediaFormat.sampleRate, 16_000)
    assert {:stop, _, {1008, _}, _} = handler.handle_in(frame.(invalid), initial)

    assert {:stop, _, {1008, _}, _} =
             handler.handle_in(frame.(%{event: "start", start: "bad"}), initial)

    {:ok, state} = handler.handle_in(frame.(start_message(:twilio)), initial)
    on_exit(fn -> handler.terminate(:normal, state) end)

    for message <- [
          %{event: "media", streamSid: "wrong", media: %{chunk: "1", payload: "/w=="}},
          %{event: "media", streamSid: "stream-1", media: %{chunk: "1", payload: "%%%"}},
          %{
            event: "media",
            streamSid: "stream-1",
            media: %{chunk: "1", payload: Base.encode64(:binary.copy(<<255>>, 16_001))}
          }
        ] do
      assert {:stop, _, {1008, _}, _} = handler.handle_in(frame.(message), state)
    end

    media = %{event: "media", streamSid: "stream-1", media: %{chunk: "1", payload: "/w=="}}
    {:ok, state} = handler.handle_in(frame.(media), state)
    assert {:stop, _, {1008, _}, _} = handler.handle_in(frame.(media), state)

    assert {:stop, _, {1008, _}, _} =
             handler.handle_in(frame.(put_in(media.media.chunk, "3")), state)
  end

  test "telephony barge-in clears provider playback and kills the previous turn" do
    owner = self()

    tts =
      {AudioFlow.Adapters.Function,
       [
         run: fn _, emit ->
           emit.(%AudioFlow.Audio{sample_rate: 16_000, data: :binary.copy(<<0>>, 1280)})
           send(owner, {:speaking, self()})
           Process.sleep(:infinity)
         end
       ]}

    socket =
      connect(AudioFlow.Telephony.WebSocket,
        provider: :twilio,
        session: Keyword.put(Demo.options(), :tts, tts),
        vad: {AudioFlow.Test.AlwaysSpeechDetector, []},
        endpoint_options: [pre_roll_ms: 0, max_utterance_ms: 96]
      )

    Client.send_json(socket, start_message(:twilio))

    media = %{
      event: "media",
      streamSid: "stream-1",
      media: %{chunk: "1", payload: Base.encode64(:binary.copy(<<255>>, 768))}
    }

    Client.send_json(socket, media)
    assert_receive {:speaking, task}
    monitor = Process.monitor(task)
    assert {:json, %{"event" => "media"}} = Client.recv(socket)
    assert {:json, %{"event" => "media"}} = Client.recv(socket)
    Client.send_json(socket, put_in(media.media.chunk, "2"))
    assert {:json, %{"event" => "clear", "streamSid" => "stream-1"}} = Client.recv(socket)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
    Client.close(socket)
  end

  test "RTVI custom audio is split into SDK-sized whole-sample messages" do
    handler = AudioFlow.RTVI.WebSocket
    {:ok, state} = handler.init(session: Demo.options())
    on_exit(fn -> handler.terminate(:normal, state) end)
    ref = make_ref()
    state = %{state | pcm: %{state.pcm | turn: {ref, 1}}}
    data = :binary.copy(<<123, 0>>, 30_001)
    tag = make_ref()
    audio = %AudioFlow.Audio{sample_rate: 16_000, data: data}

    assert {:push, frames, _state} =
             handler.handle_info(
               {AudioFlow.Transport.Connection, :push, {state.pcm.session, ref}, audio,
                {self(), tag}},
               state
             )

    assert_receive {^tag, :ok}
    assert [_, _, _] = frames

    decoded =
      for {:text, json} <- frames do
        assert byte_size(json) < 64_000

        assert %{
                 "type" => "bot-tts-audio",
                 "data" => %{"sample_rate" => 16_000, "audio" => encoded}
               } = JSON.decode!(json)

        bytes = Base.decode64!(encoded)
        assert rem(byte_size(bytes), 2) == 0
        bytes
      end

    assert IO.iodata_to_binary(decoded) == data
  end
end
