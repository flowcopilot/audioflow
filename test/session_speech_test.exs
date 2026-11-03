defmodule AudioFlow.SessionSpeechTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Function
  alias AudioFlow.Audio
  alias AudioFlow.Text

  defmodule Output do
    @behaviour AudioFlow.Output
    def start_turn(owner, key), do: report(owner, {:start, key})
    def push(owner, key, audio), do: report(owner, {:push, key, audio})
    def finish(owner, key), do: report(owner, {:finish, key})
    def flush(owner, key), do: report(owner, {:flush, key})

    defp report(owner, event) do
      send(owner, event)
      :ok
    end
  end

  defp audio, do: %Audio{data: <<1, 0, 2, 0>>, sample_rate: 24_000}

  defp start(run, options \\ []) do
    {:ok, session} =
      AudioFlow.start_session(
        [speech_to_speech: {Function, run: run}, output: {Output, self()}] ++ options
      )

    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    session
  end

  test "mixed events route without stage adapters and late transcripts are valid" do
    pcm = audio()

    session =
      start(fn ^pcm, emit ->
        :ok = emit.({:audio, pcm})
        :ok = emit.({:text, "Hello"})
        emit.({:transcript, "Hi"})
      end)

    assert {:error, {:unsupported_input, :text}} = AudioFlow.submit(session, %Text{data: "hi"})
    {:ok, turn} = AudioFlow.submit(session, pcm)
    assert_receive {AudioFlow, ^session, ^turn, {:audio, ^pcm}}
    assert_receive {:push, {^session, ^turn}, ^pcm}
    assert_receive {AudioFlow, ^session, ^turn, {:text, "Hello"}}
    assert_receive {AudioFlow, ^session, ^turn, {:transcript, "Hi"}}
    assert_receive {AudioFlow, ^session, ^turn, {:done, %{events: 3}}}
    assert_receive {:finish, {^session, ^turn}}
  end

  test "cancel, timeout and stop terminate the owning task and flush" do
    owner = self()

    for action <- [:cancel, :timeout, :stop] do
      session =
        start(
          fn _, emit ->
            emit.({:audio, audio()})
            send(owner, {:blocked, self()})

            receive do
              :never -> :ok
            end
          end,
          timeout_ms: if(action == :timeout, do: 150, else: 5000)
        )

      {:ok, turn} = AudioFlow.submit(session, audio())
      assert_receive {:blocked, worker}
      ref = Process.monitor(worker)
      assert {:error, :busy} = AudioFlow.submit(session, audio())

      case action do
        :cancel ->
          assert :ok = AudioFlow.cancel(session)
          assert_receive {AudioFlow, ^session, ^turn, {:cancelled, _}}
          assert {:error, :stale_turn} = GenServer.call(session, {:emit, turn, :text, "late"})

        :timeout ->
          assert_receive {AudioFlow, ^session, ^turn, {:error, :timeout, _}}, 1000

        :stop ->
          assert :ok = AudioFlow.stop_session(session)
      end

      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
      assert_receive {:flush, {^session, ^turn}}
    end
  end

  test "mixed outputs obey event and cumulative byte budgets and validate event types" do
    for {options, events, reason} <- [
          {[max_events: 1], [{:text, "a"}, {:text, "b"}], :output_limit},
          {[max_output_bytes: 4], [{:text, "a"}, {:audio, audio()}], :output_limit},
          {[], [{:audio, "bad"}], :invalid_output},
          {[], [{:vector, [1]}], :invalid_output}
        ] do
      session =
        start(
          fn _, emit ->
            Enum.each(events, emit)
            :ok
          end,
          options
        )

      {:ok, turn} = AudioFlow.submit(session, audio())
      assert_receive {AudioFlow, ^session, ^turn, {:error, ^reason, _}}
      assert_receive {:flush, {^session, ^turn}}
    end
  end

  defmodule RejectOutput do
    @behaviour AudioFlow.Output
    def start_turn(_, _), do: :ok
    def push(_, _, _), do: {:error, :offline}
    def finish(_, _), do: :ok
    def flush(_, _), do: :ok
  end

  test "input bounds, adapter failures and output failures do not poison the next turn" do
    owner = self()

    session =
      start(
        fn _, emit ->
          send(owner, {:running, self()})

          receive do
            :fail -> {:error, :remote_error}
            :finish -> emit.({:text, "ok"})
          end
        end,
        max_input_bytes: 4
      )

    assert {:error, :input_too_large} = AudioFlow.submit(session, %{audio() | data: <<0::48>>})
    {:ok, failed} = AudioFlow.submit(session, audio())
    assert_receive {:running, worker}
    send(worker, :fail)

    assert_receive {AudioFlow, ^session, ^failed,
                    {:error, {:adapter_error, Function, :remote_error}, _}}

    {:ok, next} = AudioFlow.submit(session, audio())
    assert_receive {:running, worker}
    send(worker, :finish)
    assert_receive {AudioFlow, ^session, ^next, {:done, _}}

    {:ok, rejected} =
      AudioFlow.start_session(
        speech_to_speech: {Function, run: fn _, emit -> emit.({:audio, audio()}) end},
        output: {RejectOutput, nil}
      )

    on_exit(fn -> if Process.alive?(rejected), do: AudioFlow.stop_session(rejected) end)
    {:ok, turn} = AudioFlow.submit(rejected, audio())
    assert_receive {AudioFlow, ^rejected, ^turn, {:error, {:output, :offline}, _}}
  end

  test "history and incompatible modes are rejected explicitly" do
    for extra <- [
          [history: true],
          [llm: {Function, []}],
          [graph: %AudioFlow.Graph.Plan{steps: %{}, inputs: %{}}]
        ] do
      assert {:error, _} = AudioFlow.start_session([speech_to_speech: {Function, []}] ++ extra)
    end
  end
end
