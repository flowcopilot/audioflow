defmodule AudioFlow.DuplexCoreTest do
  # The generic AudioFlow.Duplex lifecycle, with a fake adapter and a local
  # WebSocket peer. It needs no media build.
  use ExUnit.Case, async: true
  alias AudioFlow.Audio
  alias AudioFlow.Duplex

  defmodule Fake do
    @moduledoc false
    # Text frames from the peer are commands: "ready", "text <s>", "audio <bytes>",
    # "fail" (adapter error) and "bogus" (an event that the session rejects).
    @behaviour AudioFlow.Duplex.Adapter

    @impl true
    def config(options) do
      %{
        url: Keyword.fetch!(options, :url),
        headers: [],
        sample_rate: 16_000,
        input_flow: Keyword.get(options, :input_flow, :answered),
        options: []
      }
    end

    @impl true
    def init(_options), do: :state

    @impl true
    def handle_frame({:text, "ready"}, state), do: {:ok, [:ready], [], state}
    def handle_frame({:text, "text " <> text}, state), do: {:ok, [{:text, text}], [], state}

    def handle_frame({:text, "audio " <> size}, state) do
      data = :binary.copy(<<0>>, String.to_integer(size))
      {:ok, [{:audio, %Audio{data: data, sample_rate: 16_000}}], [], state}
    end

    def handle_frame({:text, "fail"}, _state), do: {:error, :adapter_failure}
    def handle_frame({:text, "bogus"}, state), do: {:ok, [:bogus], [], state}
    def handle_frame(_frame, state), do: {:ok, [], [], state}

    @impl true
    def handle_audio(%Audio{data: data}, state), do: {:ok, [{:binary, data}], state}
  end

  defmodule Peer do
    @moduledoc false
    @behaviour WebSock

    def init(test) do
      send(test, {:peer, self()})
      {:ok, test}
    end

    def handle_in({data, opcode: opcode}, test) do
      send(test, {:client, opcode, data})
      {:ok, test}
    end

    def handle_info({:push, frames}, test), do: {:push, frames, test}
    def handle_info(:close, test), do: {:stop, :normal, test}

    def terminate(_reason, test) do
      send(test, :peer_closed)
      :ok
    end
  end

  defmodule Endpoint do
    @moduledoc false
    def init(test), do: test

    def call(conn, test),
      do: conn |> WebSockAdapter.upgrade(Peer, test, []) |> Plug.Conn.halt()
  end

  defp url do
    server =
      start_supervised!(
        {Bandit, plug: {Endpoint, self()}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "ws://127.0.0.1:#{port}/duplex"
  end

  defp start(options \\ []) do
    {owner, options} = Keyword.pop(options, :owner, self())
    {adapter, options} = Keyword.pop(options, :adapter, [])
    {:ok, duplex} = start_duplex(owner, [url: url()] ++ adapter, options)
    assert_receive {:peer, peer}, 5000
    {duplex, peer}
  end

  defp start_duplex(owner, adapter, options),
    do: Duplex.start_link([owner: owner, adapter: {Fake, adapter}] ++ options)

  defp ready(options \\ []) do
    {duplex, peer} = start(options)
    send(peer, {:push, [{:text, "ready"}]})
    assert_receive {Duplex, ^duplex, :ready}, 5000
    {duplex, peer}
  end

  defp texts(peer, texts), do: send(peer, {:push, Enum.map(texts, &{:text, "text " <> &1})})

  defp clock do
    ref = :atomics.new(1, [])
    {fn -> :atomics.get(ref, 1) end, fn ms -> :atomics.add(ref, 1, ms) end}
  end

  test "model output reaches the owner and pushed audio reaches the model" do
    {duplex, peer} = ready()

    texts(peer, ["hello"])
    send(peer, {:push, [{:text, "audio 4"}]})
    assert_receive {Duplex, ^duplex, {:text, "hello"}}
    assert_receive {Duplex, ^duplex, {:audio, %Audio{data: <<0, 0, 0, 0>>, sample_rate: 16_000}}}

    assert :ok = Duplex.push(duplex, %Audio{data: <<1, 0, 2, 0>>, sample_rate: 16_000})
    assert_receive {:client, :binary, <<1, 0, 2, 0>>}
  end

  test "push is rejected before ready and for the wrong rate" do
    {duplex, peer} = start()
    assert {:error, :not_ready} = Duplex.push(duplex, %Audio{data: <<0, 0>>, sample_rate: 16_000})

    send(peer, {:push, [{:text, "ready"}]})
    assert_receive {Duplex, ^duplex, :ready}

    assert {:error, :invalid_audio} =
             Duplex.push(duplex, %Audio{data: <<0, 0>>, sample_rate: 8_000})

    assert Process.alive?(duplex)
  end

  test "an adapter error and an invalid event fail the session once, then close it" do
    for {command, reason} <- [{"fail", :adapter_failure}, {"bogus", :invalid_event}] do
      {duplex, peer} = ready()
      ref = Process.monitor(duplex)
      send(peer, {:push, [{:text, command}]})

      assert_receive {Duplex, ^duplex, {:error, ^reason}}
      assert_receive {Duplex, ^duplex, :closed}
      assert_receive {:DOWN, ^ref, :process, ^duplex, :normal}
      assert_receive :peer_closed
    end
  end

  describe "incoming byte bounds" do
    test "one window fails with :response_too_large" do
      {duplex, peer} = ready(max_response_bytes: 300, response_window_ms: 60_000)

      texts(peer, List.duplicate(String.duplicate("a", 50), 8))

      assert_receive {Duplex, ^duplex, {:error, :response_too_large}}
      assert_receive {Duplex, ^duplex, :closed}
      assert_receive :peer_closed
    end

    test "total bytes beyond the limit are fine when they arrive in later windows" do
      {now, advance} = clock()

      {duplex, peer} =
        ready(max_response_bytes: 300, response_window_ms: 1_000, clock: now)

      for index <- 1..20 do
        texts(peer, [String.duplicate("a", 50)])
        assert_receive {Duplex, ^duplex, {:text, _}}, 1_000, "message #{index}"
        advance.(1_000)
      end

      refute_received {Duplex, ^duplex, {:error, _}}
      assert Process.alive?(duplex)
    end

    test "a message larger than :max_message_bytes fails the session" do
      {duplex, peer} = ready(max_message_bytes: 500)

      texts(peer, [String.duplicate("a", 2_000)])

      assert_receive {Duplex, ^duplex, {:error, :response_too_large}}
      assert_receive {Duplex, ^duplex, :closed}
    end
  end

  describe "owner" do
    test "exit closes the connection without an owner message" do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      {duplex, _peer} = start(owner: owner)
      ref = Process.monitor(duplex)

      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^ref, :process, ^duplex, :normal}
      assert_receive :peer_closed
    end

    test "a full mailbox fails the session at the exact limit when the limit is small" do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      {duplex, peer} = start(owner: owner, max_owner_queue: 3)
      ref = Process.monitor(duplex)

      send(peer, {:push, [{:text, "ready"}]})
      texts(peer, ["one", "two", "three"])

      assert_receive {:DOWN, ^ref, :process, ^duplex, :normal}

      assert {:messages,
              [
                {Duplex, ^duplex, :ready},
                {Duplex, ^duplex, {:text, "one"}},
                {Duplex, ^duplex, {:text, "two"}},
                {Duplex, ^duplex, {:error, :owner_overloaded}},
                {Duplex, ^duplex, :closed}
              ]} = Process.info(owner, :messages)

      Process.exit(owner, :kill)
    end

    test "a full mailbox still fails the session when the limit is large" do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      {duplex, peer} = start(owner: owner, max_owner_queue: 40)
      ref = Process.monitor(duplex)

      send(peer, {:push, [{:text, "ready"}]})
      texts(peer, for(index <- 1..200, do: "event #{index}"))

      assert_receive {:DOWN, ^ref, :process, ^duplex, :normal}
      {:messages, messages} = Process.info(owner, :messages)

      assert {Duplex, ^duplex, {:error, :owner_overloaded}} = Enum.at(messages, -2)
      # The session reads the mailbox length at most every 32 events.
      assert length(messages) in 40..(40 + 32 + 2)

      Process.exit(owner, :kill)
    end
  end

  test "a session that runs the version 1 state keeps working after a hot upgrade" do
    {duplex, peer} = ready()
    state = :sys.get_state(duplex)

    old =
      state
      |> Map.drop([:window_ms, :window_start, :window_bytes, :partial_bytes])
      |> Map.put(:response_bytes, 0)

    old = old |> Map.drop([:max_message, :clock, :check_in])

    :sys.replace_state(duplex, fn _ -> old end)
    :ok = :sys.suspend(duplex)
    :ok = :sys.change_code(duplex, Duplex, 1, nil)
    :ok = :sys.resume(duplex)

    texts(peer, ["after"])
    assert_receive {Duplex, ^duplex, {:text, "after"}}
    assert Process.alive?(duplex)
  end

  test "reports connect_failed when no server listens" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    {:ok, duplex} = start_duplex(self(), [url: "ws://127.0.0.1:#{port}/duplex"], [])

    assert_receive {Duplex, ^duplex, {:error, :connect_failed}}
    assert_receive {Duplex, ^duplex, :closed}
  end

  test "reports connection_closed when the model closes the socket" do
    {duplex, peer} = ready()
    send(peer, :close)

    assert_receive {Duplex, ^duplex, {:error, :connection_closed}}
    assert_receive {Duplex, ^duplex, :closed}
  end

  test "stop closes the connection, and later calls report it closed" do
    {duplex, _peer} = ready()

    assert :ok = Duplex.stop(duplex)
    assert_receive {Duplex, ^duplex, :closed}
    assert_receive :peer_closed
    assert {:error, :closed} = Duplex.push(duplex, %Audio{data: <<0, 0>>, sample_rate: 16_000})
    assert :ok = Duplex.stop(duplex)
  end

  describe "realtime input pacing" do
    test "the lead is measured against the injected clock" do
      {now, advance} = clock()

      {duplex, _peer} =
        ready(
          adapter: [input_flow: :realtime],
          max_input_lead_ms: 400,
          max_chunk_bytes: 32_000,
          clock: now
        )

      # 80 ms of 16 kHz audio. Time moves with the audio, so there is no lead.
      chunk = %Audio{data: :binary.copy(<<0>>, 2_560), sample_rate: 16_000}

      for _ <- 1..30 do
        assert :ok = Duplex.push(duplex, chunk)
        advance.(80)
      end

      # Time stands still: five chunks fill the 400 ms bound, the sixth is refused.
      results = for _ <- 1..6, do: Duplex.push(duplex, chunk)
      assert results == [:ok, :ok, :ok, :ok, :ok, {:error, :overloaded}]

      # The bound reopens as time passes.
      advance.(80)
      assert :ok = Duplex.push(duplex, chunk)
      assert Process.alive?(duplex)
    end
  end

  describe "options" do
    test "invalid session options raise in the caller" do
      for options <- [
            [adapter: {Fake, url: "ws://127.0.0.1:1/x"}],
            [owner: self()],
            [owner: self(), adapter: {Fake, url: "ws://127.0.0.1:1/x"}, max_owner_queue: 0],
            [owner: self(), adapter: {Fake, url: "ws://127.0.0.1:1/x"}, max_message_bytes: 0],
            [owner: self(), adapter: {Fake, url: "ws://127.0.0.1:1/x"}, clock: :now]
          ] do
        assert_raise NimbleOptions.ValidationError, fn -> Duplex.start_link(options) end
      end
    end

    test "invalid adapter options raise in the caller" do
      for adapter <- [
            {Fake, url: "http://127.0.0.1:1/x"},
            {Fake, url: "ws://user:secret@127.0.0.1:1/x"},
            {Fake, url: "ws://127.0.0.1:1/x", input_flow: :both}
          ] do
        assert_raise ArgumentError, fn -> Duplex.start_link(owner: self(), adapter: adapter) end
      end
    end
  end
end
