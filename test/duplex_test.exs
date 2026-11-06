if System.get_env("AUDIOFLOW_MEDIA") == "1" do
  defmodule AudioFlow.DuplexTest do
    use ExUnit.Case, async: true
    alias AudioFlow.Audio
    alias AudioFlow.Duplex
    alias AudioFlow.Test.MoshiServer
    alias Membrane.Ogg.Page

    # One Moshi step: 80 ms of 24 kHz mono s16le.
    @frame_bytes 3_840

    defp tone(bytes) do
      for i <- 0..(div(bytes, 2) - 1),
          into: <<>>,
          do: <<round(8000 * :math.sin(i / 10))::little-signed-16>>
    end

    defp chunk(bytes \\ @frame_bytes), do: %Audio{data: tone(bytes), sample_rate: 24_000}

    defp start(server_options, options \\ []) do
      endpoint = MoshiServer.endpoint(self(), server_options)

      {:ok, duplex} =
        Duplex.start_link([owner: self(), adapter: {Duplex.Moshi, endpoint: endpoint}] ++ options)

      assert_receive {:moshi_server, server}
      {duplex, server}
    end

    defp ready(server_options \\ [], options \\ []) do
      {duplex, server} = start(server_options, options)
      assert_receive {Duplex, ^duplex, :ready}
      # The Ogg Opus head and tags pages carry no PCM.
      assert_receive {:client_pcm, <<>>}
      {duplex, server}
    end

    defp drain(duplex, events) do
      receive do
        {Duplex, ^duplex, event} -> drain(duplex, [event | events])
      after
        0 -> events
      end
    end

    test "model audio and text arrive while microphone input continues" do
      {duplex, _server} = ready(script: %{1 => " Hi"})

      for index <- 0..2 do
        assert :ok = Duplex.push(duplex, chunk())
        assert_receive {:client_pcm, pcm}
        assert byte_size(pcm) == @frame_bytes
        assert pcm |> :binary.bin_to_list() |> Enum.any?(&(&1 != 0))

        # Each input frame is answered before the next one is pushed: no
        # end-of-turn gate holds output back while the user speaks.
        assert_receive {Duplex, ^duplex, {:audio, %Audio{data: out, sample_rate: 24_000}}}
        assert byte_size(out) == @frame_bytes
        if index == 1, do: assert_receive({Duplex, ^duplex, {:text, " Hi"}})
      end

      refute_received {Duplex, ^duplex, {:error, _}}
    end

    test "sends each complete 80 ms frame as its own message and keeps the remainder" do
      {duplex, _server} = ready()

      assert :ok = Duplex.push(duplex, chunk(1_000))
      refute_receive {:client_pcm, _}, 100

      assert :ok = Duplex.push(duplex, chunk(2 * @frame_bytes - 1_000))
      assert_receive {:client_pcm, first}
      assert_receive {:client_pcm, second}
      assert byte_size(first) == @frame_bytes and byte_size(second) == @frame_bytes
    end

    test "emits ready only after the model handshake and rejects audio before it" do
      {duplex, server} = start(handshake: :manual)

      assert {:error, :not_ready} = Duplex.push(duplex, chunk())
      refute_receive {Duplex, ^duplex, :ready}, 100

      send(server, :handshake)
      assert_receive {Duplex, ^duplex, :ready}
      assert :ok = Duplex.push(duplex, chunk())
    end

    test "bounds unanswered input and rejects invalid chunks without closing" do
      {duplex, server} =
        ready([reply: :manual], max_input_lead_ms: 200, max_chunk_bytes: @frame_bytes)

      assert {:error, :invalid_audio} =
               Duplex.push(duplex, %Audio{data: nil, sample_rate: 24_000})

      assert {:error, :invalid_audio} =
               Duplex.push(duplex, %Audio{data: tone(@frame_bytes), sample_rate: 16_000})

      assert {:error, :invalid_audio} =
               Duplex.push(duplex, %Audio{data: <<0>>, sample_rate: 24_000})

      assert {:error, :too_large} = Duplex.push(duplex, chunk(2 * @frame_bytes))

      # 200 ms bound: two 80 ms frames fit, a third does not.
      assert :ok = Duplex.push(duplex, chunk())
      assert :ok = Duplex.push(duplex, chunk())
      assert {:error, :overloaded} = Duplex.push(duplex, chunk())
      assert_receive {:client_pcm, _}
      assert_receive {:client_pcm, _}
      refute_receive {:client_pcm, _}, 100

      send(server, :reply)
      assert_receive {Duplex, ^duplex, {:audio, _}}
      assert_receive {Duplex, ^duplex, {:audio, _}}
      assert :ok = Duplex.push(duplex, chunk())
      assert_receive {:client_pcm, _}
      refute_received {Duplex, ^duplex, {:error, _}}
    end

    test "stop closes the connection and later calls report it closed" do
      {duplex, _server} = ready()

      assert :ok = Duplex.stop(duplex)
      assert_receive {Duplex, ^duplex, :closed}
      assert_receive :moshi_server_closed
      refute_received {Duplex, ^duplex, {:error, _}}
      assert {:error, :closed} = Duplex.push(duplex, chunk())
      assert :ok = Duplex.stop(duplex)
    end

    test "corrupt Opus is reported as an error without crashing the owner" do
      {duplex, server} = ready()
      ref = Process.monitor(duplex)

      page =
        Page.create_first(2)
        |> Page.append_packet!(<<3>>)
        |> Page.finalize(0)
        |> Page.serialize()

      send(server, {:push, [{:binary, <<1>> <> page}]})
      assert_receive {Duplex, ^duplex, {:error, :invalid_audio}}
      assert_receive {Duplex, ^duplex, :closed}
      assert_receive {:DOWN, ^ref, :process, ^duplex, :normal}
    end

    test "the incoming byte budget closes the connection" do
      {duplex, _server} = start([], max_response_bytes: 1)
      assert_receive {Duplex, ^duplex, {:error, :response_too_large}}
      assert_receive {Duplex, ^duplex, :closed}
      assert_receive :moshi_server_closed
    end

    test "owner exit closes the connection" do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      endpoint = MoshiServer.endpoint(self())

      {:ok, duplex} =
        Duplex.start_link(owner: owner, adapter: {Duplex.Moshi, endpoint: endpoint})

      ref = Process.monitor(duplex)
      assert_receive {:moshi_server, _server}
      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^ref, :process, ^duplex, :normal}
      assert_receive :moshi_server_closed
    end

    test "fails the session when the owner mailbox is full" do
      test = self()

      owner =
        spawn(fn ->
          receive do
            {Duplex, _, :ready} = message -> send(test, message)
          end

          Process.sleep(:infinity)
        end)

      endpoint = MoshiServer.endpoint(self())

      {:ok, duplex} =
        Duplex.start_link(
          owner: owner,
          adapter: {Duplex.Moshi, endpoint: endpoint},
          max_owner_queue: 1
        )

      ref = Process.monitor(duplex)
      assert_receive {Duplex, ^duplex, :ready}
      assert :ok = Duplex.push(duplex, chunk(2 * @frame_bytes))

      assert_receive {:DOWN, ^ref, :process, ^duplex, :normal}
      assert_receive :moshi_server_closed

      assert {:messages,
              [
                {Duplex, ^duplex, {:audio, _}},
                {Duplex, ^duplex, {:error, :owner_overloaded}},
                {Duplex, ^duplex, :closed}
              ]} = Process.info(owner, :messages)

      Process.exit(owner, :kill)
    end

    for {reason, server_options, options, action} <- [
          {:connect_timeout, [handshake: :manual], [connect_timeout_ms: 100], nil},
          {:idle_timeout, [], [idle_timeout_ms: 100], nil},
          {:session_timeout, [], [max_session_ms: 150], nil},
          {:connection_closed, [], [], :close}
        ] do
      test "reports #{reason}, then closed, and closes the connection" do
        {duplex, server} = start(unquote(server_options), unquote(options))
        ref = Process.monitor(duplex)
        if unquote(action), do: send(server, unquote(action))

        assert_receive {Duplex, ^duplex, {:error, unquote(reason)}}, 1_000
        assert_receive {Duplex, ^duplex, :closed}
        assert_receive :moshi_server_closed
        assert_receive {:DOWN, ^ref, :process, ^duplex, :normal}
      end
    end

    test "reports connect_failed when no server listens" do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      {:ok, duplex} =
        Duplex.start_link(
          owner: self(),
          adapter: {Duplex.Moshi, endpoint: "ws://127.0.0.1:#{port}/api/chat"}
        )

      assert_receive {Duplex, ^duplex, {:error, :connect_failed}}
      assert_receive {Duplex, ^duplex, :closed}
    end

    test "rejects invalid options in the caller" do
      adapter = {Duplex.Moshi, endpoint: "http://127.0.0.1:8998/api/chat"}

      assert_raise ArgumentError, fn -> Duplex.start_link(owner: self(), adapter: adapter) end

      assert_raise ArgumentError, fn ->
        Duplex.start_link(owner: self(), adapter: {Duplex.Moshi, port: 8998})
      end
    end

    @tag :http_model
    test "a local Moshi server answers continuous input" do
      endpoint = System.get_env("AUDIOFLOW_MOSHI_ENDPOINT", "ws://127.0.0.1:8998/api/chat")
      question = System.fetch_env!("AUDIOFLOW_MOSHI_PCM") |> File.read!()

      {:ok, duplex} =
        Duplex.start_link(
          owner: self(),
          adapter: {Duplex.Moshi, endpoint: endpoint},
          connect_timeout_ms: 60_000
        )

      assert_receive {Duplex, ^duplex, :ready}, 60_000
      silence = :binary.copy(<<0>>, @frame_bytes * 75)

      events =
        for <<frame::binary-size(@frame_bytes) <- question <> silence>>, reduce: [] do
          events ->
            # The first steps after server start are slow; those pushes overload.
            assert Duplex.push(duplex, %Audio{data: frame, sample_rate: 24_000}) in [
                     :ok,
                     {:error, :overloaded}
                   ]

            Process.sleep(80)
            drain(duplex, events)
        end

      assert Enum.any?(events, &match?({:audio, _}, &1))
      assert Enum.any?(events, &match?({:text, _}, &1))
      refute Enum.any?(events, &match?({:error, _}, &1))
      Duplex.stop(duplex)
    end
  end
end
