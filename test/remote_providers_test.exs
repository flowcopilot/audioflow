defmodule AudioFlow.RemoteProvidersTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Cartesia
  alias AudioFlow.Adapters.Deepgram
  alias AudioFlow.Adapters.ElevenLabs
  alias AudioFlow.Adapters.GeminiLive
  alias AudioFlow.Adapters.OpenAIRealtime
  alias AudioFlow.Audio
  alias AudioFlow.Recording.Store
  alias AudioFlow.Test.HTTPFixture, as: HTTP

  defmodule SocketFixture do
    @behaviour WebSock
    def init(owner) do
      send(owner, {:connected, self()})
      {:ok, owner}
    end

    def handle_in({data, opcode: opcode}, owner) do
      send(
        owner,
        {:client, self(), opcode, if(opcode == :text, do: JSON.decode!(data), else: data)}
      )

      {:ok, owner}
    end

    def handle_info({:event, event}, owner), do: {:push, {:text, JSON.encode!(event)}, owner}
    def handle_info({:raw, data}, owner), do: {:push, {:text, data}, owner}
    def handle_info(:close, owner), do: {:stop, :normal, owner}
    def terminate(_, owner), do: send(owner, {:disconnected, self()})
  end

  defmodule Endpoint do
    def init(owner), do: owner

    def call(conn, owner) do
      send(owner, {:handshake, conn.request_path, conn.query_string, conn.req_headers})
      conn |> WebSockAdapter.upgrade(SocketFixture, owner, []) |> Plug.Conn.halt()
    end
  end

  defp socket_options do
    server =
      start_supervised!(
        {Bandit, plug: {Endpoint, self()}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    [
      endpoint: "ws://127.0.0.1:#{port}/provider",
      model: "fixture-model",
      api_key: fn -> "test-key" end
    ]
  end

  defp start_run(module, options, rate \\ 24_000) do
    owner = self()

    Task.async(fn ->
      module.run(%Audio{data: <<1, 0, 2, 0>>, sample_rate: rate}, options, fn value ->
        send(owner, {:output, value})
        :ok
      end)
    end)
  end

  defp event(socket, event), do: send(socket, {:event, event})

  test "OpenAI GA setup waits for ack, maps audio and transcripts, waits for late input transcript" do
    task = start_run(OpenAIRealtime, socket_options())
    assert_receive {:connected, socket}
    assert_receive {:client, ^socket, :text, %{"type" => "session.update", "session" => session}}
    assert session["audio"]["input"]["turn_detection"] == nil
    assert session["audio"]["output"]["format"] == %{"type" => "audio/pcm", "rate" => 24_000}
    refute_receive {:client, ^socket, _, _}, 20
    event(socket, %{type: "session.updated"})

    assert_receive {:client, ^socket, :text,
                    %{"type" => "input_audio_buffer.append", "audio" => "AQACAA=="}}

    assert_receive {:client, ^socket, :text, %{"type" => "input_audio_buffer.commit"}}
    assert_receive {:client, ^socket, :text, %{"type" => "response.create"}}
    event(socket, %{type: "response.output_audio.delta", delta: "AQACAA=="})
    event(socket, %{type: "response.output_audio_transcript.delta", delta: "Hello"})
    event(socket, %{type: "response.done", response: %{status: "completed", output: []}})
    assert_receive {:output, {:audio, %Audio{data: <<1, 0, 2, 0>>, sample_rate: 24_000}}}
    assert_receive {:output, {:text, "Hello"}}
    refute Task.yield(task, 20)

    event(socket, %{
      type: "conversation.item.input_audio_transcription.completed",
      transcript: "Hi"
    })

    assert :ok = Task.await(task)
    assert_receive {:output, {:transcript, "Hi"}}
    assert_receive {:disconnected, ^socket}
  end

  test "Gemini waits for setupComplete and uses manual activity with distinct PCM rates" do
    task = start_run(GeminiLive, socket_options(), 16_000)
    assert_receive {:connected, socket}
    assert_receive {:client, ^socket, :text, %{"setup" => setup}}
    assert setup["realtimeInputConfig"]["automaticActivityDetection"]["disabled"]
    event(socket, %{setupComplete: %{}})
    assert_receive {:client, ^socket, :text, %{"realtimeInput" => %{"activityStart" => %{}}}}

    assert_receive {:client, ^socket, :text,
                    %{"realtimeInput" => %{"audio" => %{"mimeType" => "audio/pcm;rate=16000"}}}}

    assert_receive {:client, ^socket, :text, %{"realtimeInput" => %{"activityEnd" => %{}}}}

    event(socket, %{
      serverContent: %{
        inputTranscription: %{text: "Hi"},
        outputTranscription: %{text: "Hello"},
        modelTurn: %{
          parts: [%{inlineData: %{mimeType: "audio/pcm;rate=24000", data: "AQACAA=="}}]
        },
        turnComplete: true
      }
    })

    assert :ok = Task.await(task)
    assert_receive {:output, {:transcript, "Hi"}}
    assert_receive {:output, {:text, "Hello"}}
    assert_receive {:output, {:audio, %Audio{sample_rate: 24_000}}}
  end

  test "Session bridges provider protocols and closes sockets on cancel, timeout and stop" do
    for {module, rate} <- [{OpenAIRealtime, 24_000}, {GeminiLive, 16_000}] do
      {:ok, session} = AudioFlow.start_session(speech_to_speech: {module, socket_options()})
      {:ok, turn} = AudioFlow.submit(session, %Audio{data: <<1, 0>>, sample_rate: rate})
      assert_receive {:connected, socket}

      if module == OpenAIRealtime do
        event(socket, %{type: "session.updated"})
        event(socket, %{type: "response.output_audio.delta", delta: "AQACAA=="})
        event(socket, %{type: "response.output_audio_transcript.delta", delta: "Hello"})
        event(socket, %{type: "response.done", response: %{status: "completed", output: []}})

        event(socket, %{
          type: "conversation.item.input_audio_transcription.completed",
          transcript: "Hi"
        })
      else
        event(socket, %{setupComplete: %{}})

        event(socket, %{
          serverContent: %{
            inputTranscription: %{text: "Hi"},
            outputTranscription: %{text: "Hello"},
            modelTurn: %{
              parts: [%{inlineData: %{mimeType: "audio/pcm;rate=24000", data: "AQACAA=="}}]
            },
            turnComplete: true
          }
        })
      end

      assert_receive {AudioFlow, ^session, ^turn, {:text, "Hello"}}
      assert_receive {AudioFlow, ^session, ^turn, {:transcript, "Hi"}}
      assert_receive {AudioFlow, ^session, ^turn, {:audio, %Audio{sample_rate: 24_000}}}
      assert_receive {AudioFlow, ^session, ^turn, {:done, %{events: 3}}}
      assert_receive {:disconnected, ^socket}
      AudioFlow.stop_session(session)
    end

    for action <- [:cancel, :timeout, :stop] do
      {:ok, session} =
        AudioFlow.start_session(
          speech_to_speech: {OpenAIRealtime, socket_options()},
          timeout_ms: if(action == :timeout, do: 150, else: 5000)
        )

      {:ok, turn} = AudioFlow.submit(session, %Audio{data: <<1, 0>>, sample_rate: 24_000})
      assert_receive {:connected, socket}

      case action do
        :cancel ->
          AudioFlow.cancel(session)
          assert_receive {AudioFlow, ^session, ^turn, {:cancelled, _}}

        :timeout ->
          assert_receive {AudioFlow, ^session, ^turn, {:error, :timeout, _}}, 1000

        :stop ->
          AudioFlow.stop_session(session)
      end

      assert_receive {:disconnected, ^socket}
      if action != :stop, do: AudioFlow.stop_session(session)
    end
  end

  test "provider Session events are recorded and redacted without persisting raw PCM by default" do
    root =
      Path.join(
        System.tmp_dir!(),
        "audioflow-provider-recording-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store} = Store.new(root)
    {:ok, session} = AudioFlow.start_session(speech_to_speech: {GeminiLive, socket_options()})
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)

    recorder =
      AudioFlow.Recording.new(session, store,
        redactor: AudioFlow.Privacy.rules([{~r/alice@example\.com/, "[EMAIL]"}])
      )

    {:ok, turn} = AudioFlow.submit(session, %Audio{data: <<1, 0>>, sample_rate: 16_000})
    assert_receive {:connected, socket}
    assert_receive {:client, ^socket, :text, %{"setup" => _}}
    event(socket, %{setupComplete: %{}})
    assert_receive {:client, ^socket, :text, %{"realtimeInput" => %{"activityEnd" => %{}}}}

    event(socket, %{
      serverContent: %{
        inputTranscription: %{text: "alice@example.com"},
        outputTranscription: %{text: "alice@"}
      }
    })

    event(socket, %{
      serverContent: %{
        outputTranscription: %{text: "example.com"},
        modelTurn: %{
          parts: [%{inlineData: %{mimeType: "audio/pcm;rate=24000", data: "AQACAA=="}}]
        },
        turnComplete: true
      }
    })

    id = record_provider_turn(recorder, session, turn)
    assert {:ok, artifact} = Store.read(store, id)
    assert artifact["status"] == "done"

    assert Enum.sort(Enum.map(artifact["streams"], &{&1["kind"], &1["text"]})) ==
             [{"text", "[EMAIL]"}, {"transcript", "[EMAIL]"}]

    refute File.read!(Path.join(root, id)) =~ "alice"
    refute Enum.any?(artifact["events"], &(&1["kind"] == "audio"))
    assert_receive {:disconnected, ^socket}
  end

  defp record_provider_turn(recorder, session, turn) do
    receive do
      {AudioFlow, ^session, ^turn, _} = message ->
        case AudioFlow.Recording.consume(recorder, message) do
          {:ok, next, nil} -> record_provider_turn(next, session, turn)
          {:ok, _, id} -> id
          error -> flunk(inspect(error))
        end
    after
      3000 -> flunk("provider Session failed to terminate")
    end
  end

  test "Deepgram sends PCM and CloseStream, excludes interim results and retains final segments" do
    task = start_run(Deepgram, socket_options(), 16_000)
    assert_receive {:connected, socket}
    assert_receive {:handshake, _, query, headers}
    assert URI.decode_query(query)["encoding"] == "linear16"
    assert {"authorization", "Token test-key"} in headers
    assert_receive {:client, ^socket, :binary, <<1, 0, 2, 0>>}
    assert_receive {:client, ^socket, :text, %{"type" => "CloseStream"}}

    for {text, final} <- [{"draft", false}, {"Hello", true}, {"world", true}] do
      event(socket, %{
        type: "Results",
        is_final: final,
        channel: %{alternatives: [%{transcript: text}]}
      })
    end

    event(socket, %{type: "Metadata"})
    assert :ok = Task.await(task)
    assert_receive {:output, "Hello"}
    assert_receive {:output, " world"}
    refute_receive {:output, "draft"}
  end

  test "remote errors, malformed events, incomplete close, and response budget fail" do
    for {message, extra, expected} <- [
          {{:event, %{error: %{message: "private"}}}, [], :remote_error},
          {{:raw, "{"}, [], :invalid_event},
          {:close, [], :incomplete_stream},
          {{:raw, String.duplicate("x", 100)}, [max_response_bytes: 10], :response_too_large}
        ] do
      task = start_run(GeminiLive, socket_options() ++ extra, 16_000)
      assert_receive {:connected, socket}
      send(socket, message)
      assert {:error, ^expected} = Task.await(task)
      assert_receive {:disconnected, ^socket}
    end
  end

  test "timeout and caller cancellation close provider sockets" do
    task = start_run(GeminiLive, socket_options() ++ [timeout_ms: 100], 16_000)
    assert_receive {:connected, socket}
    assert {:error, :timeout} = Task.await(task)
    assert_receive {:disconnected, ^socket}
    task = start_run(OpenAIRealtime, socket_options())
    assert_receive {:connected, socket}
    Task.shutdown(task, :brutal_kill)
    assert_receive {:disconnected, ^socket}
  end

  test "OpenAI rejects invalid PCM, transcription failure, tools and non-completed responses" do
    for {message, expected} <- [
          {%{type: "response.output_audio.delta", delta: "not-base64"}, :invalid_audio},
          {%{type: "conversation.item.input_audio_transcription.failed"}, :transcription_failed},
          {%{type: "response.done", response: %{status: "cancelled"}}, :response_failed},
          {%{
             type: "response.done",
             response: %{status: "completed", output: [%{type: "function_call"}]}
           }, :unsupported_tool_call}
        ] do
      task = start_run(OpenAIRealtime, socket_options())
      assert_receive {:connected, socket}
      event(socket, message)
      assert {:error, ^expected} = Task.await(task)
    end
  end

  test "Deepgram errors and Gemini interruptions fail without fabricated output" do
    task = start_run(Deepgram, socket_options(), 16_000)
    assert_receive {:connected, socket}
    event(socket, %{type: "Error", description: "private"})
    assert {:error, :remote_error} = Task.await(task)

    task = start_run(GeminiLive, socket_options(), 16_000)
    assert_receive {:connected, socket}
    event(socket, %{serverContent: %{interrupted: true}})
    assert {:error, :interrupted} = Task.await(task)
  end

  defp http_options(handler) do
    {child, listener, endpoint} = HTTP.start(self(), handler)
    start_supervised!(child)
    on_exit(fn -> :gen_tcp.close(listener) end)

    [
      endpoint: endpoint,
      model: "fixture-model",
      voice_id: "voice",
      api_version: "2026-03-01",
      api_key: "key"
    ]
  end

  defp pcm_headers(socket, type \\ "application/octet-stream") do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\nContent-Type: #{type}\r\nTransfer-Encoding: chunked\r\n\r\n"
    )
  end

  test "TTS caller cancellation releases the HTTP connection" do
    owner = self()

    options =
      http_options(fn socket, _ ->
        pcm_headers(socket)
        HTTP.chunk(socket, <<1, 0>>)
        send(owner, {:peer_result, :gen_tcp.recv(socket, 0, 2_000)})
      end)

    task =
      Task.async(fn ->
        Cartesia.run("Hello", options, fn value ->
          send(owner, {:pcm, value})
          :ok
        end)
      end)

    assert_receive {:pcm, _}
    Task.shutdown(task, :brutal_kill)
    assert_receive {:peer_result, {:error, :closed}}, 3_000
  end

  test "both HTTP TTS providers request raw PCM and stream before EOF across odd byte boundaries" do
    for provider <- [Cartesia, ElevenLabs] do
      options =
        http_options(fn socket, _ ->
          pcm_headers(socket)
          HTTP.chunk(socket, <<1, 0, 2>>)

          receive do
            :continue -> :ok
          end

          HTTP.chunk(socket, <<0>>)
          HTTP.finish(socket)
        end)

      owner = self()

      task =
        Task.async(fn ->
          provider.run("Hello", options, fn audio ->
            send(owner, {:pcm, audio})
            :ok
          end)
        end)

      assert_receive {:http_request, server, request}

      if provider == Cartesia do
        assert request.headers["authorization"] == "Bearer key"
        assert request.headers["cartesia-version"] == "2026-03-01"
        assert request.body["voice"] == "voice"

        assert request.body["output_format"] == %{
                 "container" => "raw",
                 "encoding" => "pcm_s16le",
                 "sample_rate" => 24_000
               }
      else
        assert request.headers["xi-api-key"] == "key"
        assert request.line =~ "output_format=pcm_24000"
        assert request.body["text"] == "Hello"
      end

      assert_receive {:pcm, %Audio{data: <<1, 0>>, sample_rate: 24_000}}
      send(server, :continue)
      assert :ok = Task.await(task)
      assert_receive {:pcm, %Audio{data: <<2, 0>>}}
    end
  end

  test "TTS rejects status errors, compressed audio, incomplete samples, empty and oversized responses" do
    for {type, bytes, extra, expected} <- [
          {"application/json", "{}", [], :invalid_content_type},
          {"audio/mpeg", <<1, 2>>, [], :invalid_content_type},
          {"audio/pcm", <<1>>, [], :incomplete_sample},
          {"audio/pcm", "", [], :empty_response},
          {"audio/pcm", <<1, 2>>, [max_response_bytes: 1], :response_too_large}
        ] do
      options =
        http_options(fn socket, _ ->
          pcm_headers(socket, type)
          if bytes != "", do: HTTP.chunk(socket, bytes)
          HTTP.finish(socket)
        end)

      assert {:error, ^expected} = ElevenLabs.run("Hi", options ++ extra, fn _ -> :ok end)
    end

    options =
      http_options(fn socket, _ ->
        HTTP.headers(socket, 429)
        HTTP.finish(socket)
      end)

    assert {:error, {:http_status, 429}} = Cartesia.run("Hi", options, fn _ -> :ok end)
  end
end
