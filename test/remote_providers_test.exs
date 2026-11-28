defmodule AudioFlow.RemoteProvidersTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Cartesia
  alias AudioFlow.Adapters.ElevenLabs
  alias AudioFlow.Adapters.FishAudio
  alias AudioFlow.Adapters.FishAudioAPI
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

  test "OpenAI fails a finished response without an input transcript after the grace time" do
    task = start_run(OpenAIRealtime, socket_options() ++ [transcript_grace_ms: 100])
    assert_receive {:connected, socket}
    event(socket, %{type: "session.updated"})
    event(socket, %{type: "response.done", response: %{status: "completed", output: []}})

    assert {:error, :transcript_timeout} = Task.await(task)
  end

  test "timeout_ms bounds provider time, not the time in the output callback" do
    owner = self()
    options = socket_options() ++ [timeout_ms: 300]

    task =
      Task.async(fn ->
        audio = %Audio{data: <<1, 0, 2, 0>>, sample_rate: 24_000}

        OpenAIRealtime.run(audio, options, fn
          {:text, _} ->
            send(owner, :emitting)
            Process.sleep(500)
            :ok

          _other ->
            :ok
        end)
      end)

    assert_receive {:connected, socket}
    event(socket, %{type: "session.updated"})
    event(socket, %{type: "response.output_audio_transcript.delta", delta: "Hello"})
    assert_receive :emitting

    event(socket, %{type: "response.done", response: %{status: "completed", output: []}})

    event(socket, %{
      type: "conversation.item.input_audio_transcription.completed",
      transcript: "Hi"
    })

    assert :ok = Task.await(task)
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

  @tag :tmp_dir
  test "provider Session events are recorded and redacted without persisting raw PCM by default",
       %{tmp_dir: root} do
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

  test "Gemini interruptions fail without fabricated output" do
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

  test "HTTP TTS providers stream before EOF across odd byte boundaries" do
    for provider <- [Cartesia, ElevenLabs, FishAudio, FishAudioAPI] do
      options =
        http_options(fn socket, _ ->
          pcm_headers(socket, if(provider == FishAudio, do: "audio/wav", else: "audio/pcm"))

          if provider == FishAudio do
            <<first::binary-size(17), rest::binary>> = fish_header()
            HTTP.chunk(socket, first)

            receive do
              :header_rest -> :ok
            end

            HTTP.chunk(socket, rest)
          end

          HTTP.chunk(socket, <<1, 0, 2>>)

          receive do
            :continue -> :ok
          end

          HTTP.chunk(socket, <<0>>)
          HTTP.finish(socket)
        end)

      options =
        if provider == FishAudioAPI do
          Keyword.merge(options,
            reference_id: "hosted-voice",
            model: "s2.1-pro",
            api_key: fn -> "api-key" end,
            sample_rate: 16_000,
            language: "ro",
            latency: "balanced"
          )
        else
          options
        end

      owner = self()

      task =
        Task.async(fn ->
          provider.run("Hello", options, fn audio ->
            send(owner, {:pcm, audio})
            :ok
          end)
        end)

      assert_receive {:http_request, server, request}

      if provider == FishAudio do
        refute_receive {:pcm, _}, 20
        send(server, :header_rest)
      end

      case provider do
        Cartesia ->
          assert request.headers["authorization"] == "Bearer key"
          assert request.headers["cartesia-version"] == "2026-03-01"
          assert request.body["voice"] == "voice"

          assert request.body["output_format"] == %{
                   "container" => "raw",
                   "encoding" => "pcm_s16le",
                   "sample_rate" => 24_000
                 }

        FishAudio ->
          assert request.headers["authorization"] == "Bearer key"
          assert request.body == %{"text" => "Hello", "format" => "wav", "streaming" => true}

        FishAudioAPI ->
          assert request.headers["authorization"] == "Bearer api-key"
          assert request.headers["model"] == "s2.1-pro"
          assert request.headers["content-type"] == "application/json"

          assert request.body == %{
                   "text" => "Hello",
                   "format" => "pcm",
                   "reference_id" => "hosted-voice",
                   "sample_rate" => 16_000,
                   "language" => "ro",
                   "latency" => "balanced"
                 }

        ElevenLabs ->
          assert request.headers["xi-api-key"] == "key"
          assert request.line =~ "output_format=pcm_24000"
          assert request.body["text"] == "Hello"
      end

      rate =
        case provider do
          FishAudio -> 44_100
          FishAudioAPI -> 16_000
          _ -> 24_000
        end

      assert_receive {:pcm, %Audio{data: <<1, 0>>, sample_rate: ^rate}}
      send(server, :continue)
      assert :ok = Task.await(task)
      assert_receive {:pcm, %Audio{data: <<2, 0>>}}
    end
  end

  test "hosted Fish Audio defaults to 44.1 kHz and rejects unusable configuration before HTTP" do
    options =
      http_options(fn socket, _ ->
        pcm_headers(socket)
        HTTP.chunk(socket, <<1, 0>>)
        HTTP.finish(socket)
      end)
      |> Keyword.put(:reference_id, "hosted-voice")

    assert :ok =
             FishAudioAPI.run("Hello", options, fn audio ->
               send(self(), {:pcm, audio})
               :ok
             end)

    assert_receive {:pcm, %Audio{data: <<1, 0>>, sample_rate: 44_100}}

    assert_receive {:http_request, _,
                    %{body: %{"format" => "pcm", "sample_rate" => 44_100, "latency" => "normal"}}}

    for extra <- [
          [sample_rate: 22_050],
          [sample_rate: 48_000],
          [latency: "invalid"],
          [reference_id: ""],
          [reference_id: " \t"],
          [model: ""],
          [api_key: fn -> nil end],
          [api_key: fn -> "" end]
        ] do
      assert_raise ArgumentError, fn ->
        FishAudioAPI.run("Hi", Keyword.merge(options, extra), fn _ -> flunk("unexpected PCM") end)
      end
    end

    refute_receive {:http_request, _, _}
  end

  # Independent wire fixture matching Python wave's canonical streaming header.
  defp fish_header(rate \\ 44_100, channels \\ 1, bits \\ 16, size \\ 0xFFFFFFFF) do
    riff_size = if size == 0, do: 36, else: 0xFFFFFFFF
    align = div(channels * bits, 8)

    <<"RIFF", riff_size::little-32, "WAVEfmt ", 16::little-32, 1::little-16, channels::little-16,
      rate::little-32, rate * align::little-32, align::little-16, bits::little-16, "data",
      size::little-32>>
  end

  test "Fish Speech supports unauthenticated local servers, reference voices and legacy WAV headers" do
    options =
      http_options(fn socket, _ ->
        pcm_headers(socket, "audio/wav")
        HTTP.chunk(socket, fish_header(48_000, 1, 16, 0) <> <<3, 0>>)
        HTTP.finish(socket)
      end)
      |> Keyword.delete(:api_key)
      |> Keyword.put(:reference_id, "narrator")

    assert :ok =
             FishAudio.run("[whisper] Hello", options, fn audio ->
               send(self(), {:pcm, audio})
               :ok
             end)

    assert_receive {:http_request, _, request}
    refute Map.has_key?(request.headers, "authorization")
    assert request.body["reference_id"] == "narrator"
    assert request.body["text"] == "[whisper] Hello"
    assert_receive {:pcm, %Audio{data: <<3, 0>>, sample_rate: 48_000}}
  end

  test "Fish Speech rejects invalid WAV streams and enforces HTTP budgets" do
    for {type, data, extra, expected} <- [
          {"audio/mpeg", <<1, 2>>, [], :invalid_content_type},
          {"audio/wav", "RIFF", [], :invalid_wav},
          {"audio/wav", fish_header(44_100, 2), [], :unsupported_wav},
          {"audio/wav", fish_header(44_100, 1, 32), [], :unsupported_wav},
          {"audio/wav", String.duplicate("x", 44), [], :unsupported_wav},
          {"audio/wav", fish_header(), [], :empty_response},
          {"audio/wav", fish_header() <> <<1>>, [], :incomplete_sample},
          {"audio/wav", fish_header() <> <<1, 0>>, [max_response_bytes: 45], :response_too_large}
        ] do
      options =
        http_options(fn socket, _ ->
          pcm_headers(socket, type)
          HTTP.chunk(socket, data)
          HTTP.finish(socket)
        end)

      assert {:error, ^expected} =
               FishAudio.run("Hi", options ++ extra, fn _ -> flunk("unexpected PCM") end)
    end

    options =
      http_options(fn socket, _ ->
        HTTP.headers(socket, 401)
        HTTP.finish(socket)
      end)

    assert {:error, {:http_status, 401}} = FishAudio.run("Hi", options, fn _ -> :ok end)

    assert {:error, :request_too_large} =
             FishAudio.run("Hi", options ++ [max_request_bytes: 1], fn _ -> :ok end)
  end

  test "Fish Speech omits blank reference IDs and resolves optional API-key callbacks" do
    for {reference, key} <- [{nil, nil}, {"", ""}, {" \t", "rotated-key"}] do
      options =
        http_options(fn socket, _ ->
          pcm_headers(socket, "audio/wav")
          HTTP.chunk(socket, fish_header() <> <<1, 0>>)
          HTTP.finish(socket)
        end)

      options = Keyword.merge(options, reference_id: reference, api_key: fn -> key end)
      assert :ok = FishAudio.run("Hi", options, fn _ -> :ok end)
      assert_receive {:http_request, _, request}
      refute Map.has_key?(request.body, "reference_id")
      expected = if key in [nil, ""], do: nil, else: "Bearer " <> key
      assert request.headers["authorization"] == expected
    end
  end

  test "Fish Speech rejects premature HTTP EOF after headers or partial PCM" do
    for pcm <- [<<>>, <<1, 0, 2>>] do
      options =
        http_options(fn socket, _ ->
          pcm_headers(socket, "audio/wav")
          HTTP.chunk(socket, fish_header() <> pcm)
          # The fixture closes without the terminating HTTP chunk.
        end)

      assert {:error, :http_stream_failed} = FishAudio.run("Hi", options, fn _ -> :ok end)
    end
  end

  test "Fish Speech idle timeout closes the connection before or during the WAV header" do
    owner = self()

    for partial <- [<<>>, "RIFF"] do
      options =
        http_options(fn socket, _ ->
          pcm_headers(socket, "audio/wav")
          if partial != <<>>, do: HTTP.chunk(socket, partial)
          send(owner, {:peer_result, :gen_tcp.recv(socket, 0, 2_000)})
        end)

      options = Keyword.merge(options, timeout_ms: 1_000, receive_timeout_ms: 40)

      assert {:error, :http_stream_failed} =
               FishAudio.run("Hi", options, fn _ -> flunk("unexpected PCM") end)

      assert_receive {:peer_result, {:error, :closed}}, 3_000
    end
  end

  test "Fish Speech cancellation closes the HTTP stream" do
    owner = self()

    options =
      http_options(fn socket, _ ->
        pcm_headers(socket, "audio/wav")
        HTTP.chunk(socket, fish_header() <> <<1, 0>>)
        send(owner, {:peer_result, :gen_tcp.recv(socket, 0, 2_000)})
      end)

    task =
      Task.async(fn ->
        FishAudio.run("Hi", options, fn audio ->
          send(owner, {:pcm, audio})
          :ok
        end)
      end)

    assert_receive {:pcm, _}
    Task.shutdown(task, :brutal_kill)
    assert_receive {:peer_result, {:error, :closed}}, 3_000
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
