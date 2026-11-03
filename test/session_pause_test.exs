defmodule AudioFlow.SessionPauseTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Adapters.Function
  alias AudioFlow.Output
  alias AudioFlow.Text

  defmodule Endpoint do
    @behaviour AudioFlow.Output
    @behaviour AudioFlow.PausableOutput
    def start_turn(_, _), do: :ok
    def push(owner, key, audio), do: send_ok(owner, {:pcm, key, audio.data})
    def finish(owner, key), do: send_ok(owner, {:finish, key})
    def flush(owner, key), do: send_ok(owner, {:flush, key})
    def pause(owner, key, id), do: send_ok(owner, {:pause, key, id})
    def resume(owner, key, id), do: send_ok(owner, {:resume, key, id})

    defp send_ok(owner, msg) do
      send(owner, msg)
      :ok
    end
  end

  defmodule BrokenResume do
    defdelegate start_turn(owner, key), to: Endpoint
    defdelegate push(owner, key, audio), to: Endpoint
    defdelegate finish(owner, key), to: Endpoint
    defdelegate flush(owner, key), to: Endpoint
    defdelegate pause(owner, key, id), to: Endpoint
    def resume(_, _, _), do: {:error, :driver_failure}
  end

  defp start(extra \\ []) do
    owner = self()
    options = Demo.options() ++ [history: true]

    options =
      Keyword.merge(options,
        output: {Endpoint, owner},
        llm:
          {Function,
           run: fn _, emit ->
             emit.("first")
             send(owner, {:worker, self()})

             receive do
               :continue -> emit.("second")
               :error -> throw(:broken)
               :finish -> :ok
             end
           end}
      )
      |> Keyword.merge(extra)

    {:ok, session} = AudioFlow.start_session(options)
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "hello"})
    assert_receive {:worker, worker}
    {session, turn, worker}
  end

  defp pause(session, turn, ms \\ 2_000) do
    assert {:ok, id} = Output.provisional(session, ms)
    assert_receive {:pause, {^session, ^turn}, ^id}
    assert :ok = Output.control_ack(session, turn, id, :pause, 100_000_000)
    id
  end

  test "false candidate retains worker, ordered PCM, checkpoints and untouched history" do
    {s, t, w} = start()
    assert_receive {:pcm, {^s, ^t}, first}
    before = :sys.get_state(s)
    id = pause(s, t)
    send(w, :continue)
    # Synchronous call barriers ensure the worker's second emit is held.
    assert eventually(fn -> :sys.get_state(s).held != nil end)
    held = :sys.get_state(s)
    assert Process.alive?(w)
    assert held.active.task.pid == w
    assert held.history == before.history
    assert held.active.context == before.active.context
    assert held.active.playout.checkpoints == before.active.playout.checkpoints
    refute_receive {:pcm, _, _}, 20
    assert :ok = Output.resolve(s, id, :resume)
    assert_receive {:resume, {^s, ^t}, ^id}
    refute_receive {:pcm, _, _}, 20
    assert :ok = Output.control_ack(s, t, id, :resume, 100_000_000)
    assert_receive {:pcm, {^s, ^t}, ^first}
    assert_receive {AudioFlow, ^s, ^t, {:done, _}}
    assert :sys.get_state(s).history != before.history
    assert {:error, :stale_control} = Output.control_ack(s, t, id, :resume, 100_000_000)
    assert {:error, :stale_candidate} = Output.resolve(s, id, :confirm)
  end

  test "candidate deadline confirms and retains only acknowledged prefix" do
    {s, t, w} = start()
    id = pause(s, t, 30)
    assert_receive {AudioFlow, ^s, ^t, {:cancelled, _}}, 500
    assert_receive {:flush, {^s, ^t}}
    refute Process.alive?(w)
    assert {:error, :stale_control} = Output.control_ack(s, t, id, :pause, 0)

    assert :sys.get_state(s).history.turns == [{"hello", "first"}]
  end

  test "missing endpoint ack also expires; turn timeout stays effective while paused" do
    {s, t, _} = start(timeout_ms: 60)
    assert {:ok, _} = Output.provisional(s, 500)
    assert_receive {AudioFlow, ^s, ^t, {:error, :timeout, _}}, 500
    assert :sys.get_state(s).candidate == nil
  end

  test "errors, explicit stop and session stop discard held output" do
    for action <- [:error, :cancel, :stop] do
      {s, t, w} = start()
      id = pause(s, t)

      case action do
        :error -> send(w, :error)
        :cancel -> AudioFlow.cancel(s)
        :stop -> AudioFlow.stop_session(s)
      end

      assert_receive {:flush, {^s, ^t}}, 500

      if action != :stop do
        assert eventually(fn -> :sys.get_state(s).active == nil end)
        assert {:error, :stale_candidate} = Output.resolve(s, id, :resume)
      end
    end
  end

  test "bounded held emit rejects overflow and stale/early acknowledgements" do
    {s, t, w} = start()
    id = pause(s, t)
    assert {:error, :stale_control} = Output.control_ack(s, t, id, :pause, 0)
    assert {:error, :stale_control} = Output.control_ack(s, make_ref(), id, :resume, 0)
    send(w, :continue)
    assert eventually(fn -> :sys.get_state(s).held != nil end)
    assert {:error, :output_limit} = GenServer.call(s, {:emit, t, :text, "overflow"})
    assert :ok = Output.resolve(s, id, :resume)
    assert {:error, :invalid_playback_offset} = Output.control_ack(s, t, id, :resume, -1)
    AudioFlow.cancel(s)
  end

  test "legacy output is unsupported and keeps running" do
    {s, t, w} = start(output: nil)
    assert {:error, :unsupported} = Output.provisional(s)
    send(w, :continue)
    assert_receive {AudioFlow, ^s, ^t, {:done, _}}
  end

  test "completion raced with pause waits for resume without task DOWN failure" do
    {s, t, w} = start()
    id = pause(s, t)
    send(w, :finish)
    assert eventually(fn -> :sys.get_state(s).pending_result != nil end)
    refute_receive {AudioFlow, ^s, ^t, {:done, _}}, 20
    assert :ok = Output.resolve(s, id, :resume)
    assert :ok = Output.control_ack(s, t, id, :resume, 100_000_000)
    assert_receive {AudioFlow, ^s, ^t, {:done, _}}
    id2 = pause(s, t)
    history = :sys.get_state(s).history
    assert :ok = Output.resolve(s, id2, :resume)
    assert :ok = Output.control_ack(s, t, id2, :resume, 100_000_000)
    assert :sys.get_state(s).history == history
  end

  test "candidate expiry without pause ack flushes; callback failure also cancels" do
    {s, t, w} = start()
    assert {:ok, _id} = Output.provisional(s, 20)
    assert_receive {AudioFlow, ^s, ^t, {:cancelled, _}}, 500
    refute Process.alive?(w)
    assert_receive {:flush, {^s, ^t}}

    {s, t, _} = start(output: {BrokenResume, self()})
    id = pause(s, t)
    assert {:error, :driver_failure} = Output.resolve(s, id, :resume)
    assert_receive {:flush, {^s, ^t}}
    assert :sys.get_state(s).candidate == nil
  end

  test "oversized paused output is rejected without retaining payload; stop clears held emit" do
    {s, t, w} = start(max_output_bytes: 4_000)
    id = pause(s, t)

    assert {:error, :output_limit} =
             GenServer.call(s, {:emit, t, :text, String.duplicate("x", 4_001)})

    assert :sys.get_state(s).held == nil
    send(w, :continue)
    assert eventually(fn -> :sys.get_state(s).held != nil end)
    assert :ok = Output.resolve(s, id, :confirm)
    assert_receive {:flush, {^s, ^t}}
    refute Process.alive?(w)
    assert :sys.get_state(s).held == nil
  end

  defp eventually(fun, n \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, n) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(5)
          eventually(fun, n - 1)
        )
  end
end
