defmodule AudioFlow.DuplexOpenAITest do
  use ExUnit.Case, async: true
  alias AudioFlow.Audio
  alias AudioFlow.Duplex
  alias AudioFlow.Duplex.OpenAIRealtime

  # Local peer with the OpenAI Realtime GA event framing. It reports the
  # upgrade request and every client event to the test, and pushes the events
  # that the test sends to it. It never acts on its own.
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

    def handle_info(:close, owner), do: {:stop, :normal, owner}

    def terminate(_reason, owner) do
      send(owner, :peer_closed)
      :ok
    end
  end

  defmodule Endpoint do
    def init(owner), do: owner

    def call(conn, owner) do
      send(owner, {:upgrade, conn.query_string, conn.req_headers})
      conn |> WebSockAdapter.upgrade(Peer, owner, []) |> Plug.Conn.halt()
    end
  end

  # 80 ms of 24 kHz mono s16le.
  @chunk 3_840

  defp endpoint do
    server =
      start_supervised!(
        {Bandit, plug: {Endpoint, self()}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "ws://127.0.0.1:#{port}/v1/realtime"
  end

  defp start(options \\ []) do
    adapter =
      {OpenAIRealtime,
       endpoint: endpoint(),
       model: "fixture-model",
       api_key: fn -> "fixture-key" end,
       voice: "cedar"}

    {:ok, duplex} = Duplex.start_link([owner: self(), adapter: adapter] ++ options)
    assert_receive {:peer, peer}
    {duplex, peer}
  end

  defp ready(options \\ []) do
    {duplex, peer} = start(options)
    send(peer, {:events, [%{type: "session.created", session: %{}}]})
    assert_receive {:client, %{"type" => "session.update"}}
    send(peer, {:events, [%{type: "session.updated", session: %{}}]})
    assert_receive {Duplex, ^duplex, :ready}
    {duplex, peer}
  end

  defp silence(bytes \\ @chunk), do: %Audio{data: :binary.copy(<<0>>, bytes), sample_rate: 24_000}
  defp pcm(samples), do: Base.encode64(:binary.copy(<<1, 0>>, samples))

  defp delta(response, item, samples) do
    %{
      type: "response.output_audio.delta",
      response_id: response,
      item_id: item,
      output_index: 0,
      content_index: 0,
      delta: pcm(samples)
    }
  end

  defp reply(peer, response, item, text, samples) do
    send(
      peer,
      {:events,
       [
         %{type: "response.created", response: %{id: response, status: "in_progress"}},
         delta(response, item, samples),
         %{type: "response.output_audio_transcript.delta", response_id: response, delta: text}
       ]}
    )
  end

  defp done(peer, response, status, output \\ []),
    do:
      send(
        peer,
        {:events,
         [%{type: "response.done", response: %{id: response, status: status, output: output}}]}
      )

  defp speech(peer, item, transcript) do
    send(
      peer,
      {:events,
       [
         %{type: "input_audio_buffer.speech_started", item_id: item, audio_start_ms: 0},
         %{type: "input_audio_buffer.speech_stopped", item_id: item, audio_end_ms: 900},
         %{type: "input_audio_buffer.committed", item_id: item},
         %{
           type: "conversation.item.input_audio_transcription.completed",
           item_id: item,
           content_index: 0,
           transcript: transcript
         }
       ]}
    )
  end

  test "configures server VAD replies, then is ready only after session.updated" do
    {duplex, peer} = start()

    assert_received {:upgrade, "model=fixture-model", headers}
    assert {"authorization", "Bearer fixture-key"} in headers
    assert {:error, :not_ready} = Duplex.push(duplex, silence())

    send(peer, {:events, [%{type: "session.created", session: %{}}]})
    assert_receive {:client, %{"type" => "session.update", "session" => session}}

    assert %{
             "type" => "realtime",
             "model" => "fixture-model",
             "output_modalities" => ["audio"],
             "audio" => %{
               "input" => %{
                 "format" => %{"type" => "audio/pcm", "rate" => 24_000},
                 "transcription" => %{"model" => "gpt-4o-mini-transcribe"},
                 "turn_detection" => %{
                   "type" => "server_vad",
                   "create_response" => true,
                   "interrupt_response" => true
                 }
               },
               "output" => %{
                 "format" => %{"type" => "audio/pcm", "rate" => 24_000},
                 "voice" => "cedar"
               }
             }
           } = session

    refute_receive {Duplex, ^duplex, :ready}, 100
    assert {:error, :not_ready} = Duplex.push(duplex, silence())

    send(peer, {:events, [%{type: "session.updated", session: session}]})
    assert_receive {Duplex, ^duplex, :ready}
    assert :ok = Duplex.push(duplex, silence())
    assert_receive {:client, %{"type" => "input_audio_buffer.append", "audio" => audio}}
    assert Base.decode64!(audio) == silence().data
  end

  test "several utterances share one connection; input is only appended, never committed" do
    {duplex, peer} = ready()

    for {user, response, item, text} <- [
          {"user_1", "resp_1", "item_1", "Hello."},
          {"user_2", "resp_2", "item_2", "Again."}
        ] do
      assert :ok = Duplex.push(duplex, silence())
      speech(peer, user, "Question #{user}")
      reply(peer, response, item, text, 480)
      done(peer, response, "completed")

      assert_receive {Duplex, ^duplex, {:speech_started, ^user}}
      assert_receive {Duplex, ^duplex, {:transcript, ^user, "Question " <> ^user}}
      assert_receive {Duplex, ^duplex, {:response, ^response, :created}}
      assert_receive {Duplex, ^duplex, {:output, ^item}}
      assert_receive {Duplex, ^duplex, {:audio, %Audio{data: data, sample_rate: 24_000}}}
      assert byte_size(data) == 960
      assert_receive {Duplex, ^duplex, {:text, ^text}}
      assert_receive {Duplex, ^duplex, {:response, ^response, :completed}}
    end

    for _ <- 1..2, do: assert_receive({:client, %{"type" => "input_audio_buffer.append"}})
    refute_received {:client, _}
    refute_received {:peer, _}
  end

  test "continuous silence well past the input lead is accepted at the real-time rate" do
    {duplex, _peer} = ready(max_input_lead_ms: 400)

    # 2.4 s of silence at the browser rate, with no model output at all.
    for _ <- 1..30 do
      assert :ok = Duplex.push(duplex, silence())
      Process.sleep(80)
    end

    # A burst far ahead of the clock is refused, and the call stays open.
    results = for _ <- 1..40, do: Duplex.push(duplex, silence())
    assert {:error, :overloaded} in results
    assert Process.alive?(duplex)
    refute_received {Duplex, ^duplex, {:error, _}}
  end

  test "speech during a reply drops its late audio and text, and the next reply plays" do
    {duplex, peer} = ready()
    reply(peer, "resp_1", "item_1", "Long answer", 2_400)
    assert_receive {Duplex, ^duplex, {:audio, _}}
    assert_receive {Duplex, ^duplex, {:text, "Long answer"}}

    send(
      peer,
      {:events,
       [
         %{type: "input_audio_buffer.speech_started", item_id: "user_2", audio_start_ms: 10},
         delta("resp_1", "item_1", 2_400),
         %{type: "response.output_audio_transcript.delta", response_id: "resp_1", delta: " late"}
       ]}
    )

    assert_receive {Duplex, ^duplex, {:speech_started, "user_2"}}
    done(peer, "resp_1", "cancelled")
    assert_receive {Duplex, ^duplex, {:response, "resp_1", :cancelled}}
    refute_received {Duplex, ^duplex, {:audio, _}}
    refute_received {Duplex, ^duplex, {:text, " late"}}

    # Input continues during and after the interruption.
    assert :ok = Duplex.push(duplex, silence())
    reply(peer, "resp_2", "item_2", "Short", 480)
    assert_receive {Duplex, ^duplex, {:output, "item_2"}}
    assert_receive {Duplex, ^duplex, {:audio, _}}
    assert_receive {Duplex, ^duplex, {:text, "Short"}}
  end

  test "played audio of the interrupted reply truncates the provider item, capped and once" do
    {duplex, peer} = ready()
    # 200 ms of reply audio in two deltas.
    reply(peer, "resp_1", "item_1", "Hi", 2_400)
    send(peer, {:events, [delta("resp_1", "item_1", 2_400)]})
    for _ <- 1..2, do: assert_receive({Duplex, ^duplex, {:audio, _}})

    assert {:error, :stale} = Duplex.control(duplex, {:played, "item_1", 50})

    speech(peer, "user_2", "Wait")
    assert_receive {Duplex, ^duplex, {:speech_started, "user_2"}}

    assert {:error, :stale} = Duplex.control(duplex, {:played, "other", 50})
    assert {:error, :invalid_command} = Duplex.control(duplex, {:played, "item_1", -1})
    assert :ok = Duplex.control(duplex, {:played, "item_1", 120})

    assert_receive {:client,
                    %{
                      "type" => "conversation.item.truncate",
                      "item_id" => "item_1",
                      "content_index" => 0,
                      "audio_end_ms" => 120,
                      "event_id" => event_id
                    }}

    assert {:error, :stale} = Duplex.control(duplex, {:played, "item_1", 100})

    # A rejected truncation does not end the call.
    send(
      peer,
      {:events, [%{type: "error", error: %{type: "invalid_request_error", event_id: event_id}}]}
    )

    assert :ok = Duplex.push(duplex, silence())

    # A report at or past the received audio needs no truncation.
    reply(peer, "resp_2", "item_2", "Ok", 2_400)
    assert_receive {Duplex, ^duplex, {:output, "item_2"}}
    speech(peer, "user_3", "More")
    assert_receive {Duplex, ^duplex, {:speech_started, "user_3"}}
    assert :ok = Duplex.control(duplex, {:played, "item_2", 5_000})
    refute_receive {:client, %{"type" => "conversation.item.truncate"}}, 100
    refute_received {Duplex, ^duplex, {:error, _}}
  end

  test "provider errors, tool calls and invalid audio fail the call with a reason" do
    for {events, reason} <- [
          {[%{type: "error", error: %{type: "server_error", code: "boom", message: "detail"}}],
           {:remote_error, "boom"}},
          {[
             %{
               type: "response.done",
               response: %{id: "r", status: "completed", output: [%{type: "function_call"}]}
             }
           ], :unsupported_tool_call},
          {[%{type: "response.output_audio.delta", response_id: "r", item_id: "i", delta: "%%"}],
           :invalid_audio}
        ] do
      {duplex, peer} = ready()
      ref = Process.monitor(duplex)
      send(peer, {:events, events})
      assert_receive {Duplex, ^duplex, {:error, ^reason}}
      assert_receive {Duplex, ^duplex, :closed}
      assert_receive {:DOWN, ^ref, :process, ^duplex, :normal}
      assert_receive :peer_closed
    end
  end

  test "an error before session.updated fails the start" do
    {duplex, peer} = start()

    send(
      peer,
      {:events, [%{type: "error", error: %{type: "invalid_request_error", code: "bad_model"}}]}
    )

    assert_receive {Duplex, ^duplex, {:error, {:remote_error, "bad_model"}}}
    assert_receive {Duplex, ^duplex, :closed}
    refute_received {Duplex, ^duplex, :ready}
  end

  test "stop closes the connection; a new call starts a new provider session" do
    {duplex, _peer} = ready()
    assert :ok = Duplex.stop(duplex)
    assert_receive {Duplex, ^duplex, :closed}
    assert_receive :peer_closed
    assert {:error, :closed} = Duplex.control(duplex, {:played, "item", 0})

    {second, _peer} = ready()
    assert second != duplex
  end

  test "rejects invalid options in the caller" do
    for options <- [
          [api_key: "k"],
          [model: "m"],
          [model: "", api_key: "k"],
          [model: "m", api_key: "k", endpoint: "https://api.openai.com/v1/realtime"]
        ] do
      assert_raise ArgumentError, fn ->
        Duplex.start_link(owner: self(), adapter: {OpenAIRealtime, options})
      end
    end
  end
end
