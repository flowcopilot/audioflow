defmodule AudioFlow.WorkerTest do
  use ExUnit.Case, async: true
  alias AudioFlow.{Adapters.Function, Audio, Worker}

  defp worker(run, options \\ []) do
    start_supervised!(
      Supervisor.child_spec({Worker, [adapter: {Function, run: run}] ++ options}, id: make_ref())
    )
  end

  test "each output waits for acknowledgement and full workers reject new requests" do
    owner = self()

    worker =
      worker(fn input, emit ->
        emit.({input, 1})
        send(owner, :first_acknowledged)
        emit.({input, 2})
      end)

    task =
      Task.async(fn ->
        Worker.run(:first, [worker: worker], fn output ->
          send(owner, {:output, self(), output})

          receive do
            :ack -> :ok
          end
        end)
      end)

    assert_receive {:output, client, {:first, 1}}

    assert {:error, {:worker_rejected, :busy}} =
             Worker.run(:second, [worker: worker], fn _ -> :ok end)

    refute_receive :first_acknowledged, 20
    send(client, :ack)
    assert_receive :first_acknowledged
    assert_receive {:output, ^client, {:first, 2}}
    send(client, :ack)
    assert :ok = Task.await(task)
    assert :ok = Worker.run(:next, [worker: worker], fn _ -> :ok end)
  end

  test "adapter failures release capacity and leave the worker available" do
    worker =
      worker(fn
        :error, _ -> {:error, :model_error}
        :exception, _ -> raise "model failed"
        :kill, _ -> Process.exit(self(), :kill)
        :ok, emit -> emit.("Recovered.")
      end)

    for {input, expected} <- [
          {:error, {:adapter_error, Function, :model_error}},
          {:exception, {:exception, "model failed"}},
          {:kill, {:task_exit, :killed}}
        ] do
      assert {:error, ^expected} = Worker.run(input, [worker: worker], fn _ -> :ok end)
      assert :ok = Worker.run(:ok, [worker: worker], fn "Recovered." -> :ok end)
    end
  end

  test "a worker can run two admitted requests at the same time" do
    owner = self()

    worker =
      worker(
        fn input, emit ->
          send(owner, {:inference, input, self()})

          receive do
            :continue -> emit.(input)
          end
        end,
        max_concurrency: 2
      )

    tasks =
      for input <- [:one, :two] do
        Task.async(fn -> Worker.run(input, [worker: worker], fn _ -> :ok end) end)
      end

    assert_receive {:inference, :one, first}
    assert_receive {:inference, :two, second}
    assert first != second

    assert {:error, {:worker_rejected, :busy}} =
             Worker.run(:three, [worker: worker], fn _ -> :ok end)

    send(first, :continue)
    send(second, :continue)
    assert Enum.map(tasks, &Task.await/1) == [:ok, :ok]
  end

  test "an admission deadline cancels a request even when the worker replies late" do
    worker =
      worker(fn
        :late, _ ->
          receive do
            :continue -> :ok
          end

        :ready, emit ->
          emit.("Ready.")
      end)

    :ok = :sys.suspend(worker)

    try do
      assert {:error, {:worker_admission_failed, {:timeout, _}}} =
               Worker.run(:late, [worker: worker, timeout_ms: 20], fn _ -> :ok end)
    after
      :sys.resume(worker)
    end

    assert :ok = Worker.run(:ready, [worker: worker], fn "Ready." -> :ok end)
  end

  test "session cancellation stops inference and the same worker serves the next turn" do
    owner = self()

    worker =
      worker(fn _, emit ->
        send(owner, {:inference, self()})

        receive do
          :continue -> emit.("A reply.")
        end
      end)

    {:ok, session} =
      AudioFlow.start_session(
        Keyword.put(AudioFlow.Adapters.Demo.options(), :llm, {Worker, worker: worker})
      )

    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    audio = %Audio{data: <<0, 0>>, sample_rate: 16_000}
    {:ok, turn} = AudioFlow.submit(session, audio)
    assert_receive {:inference, inference}
    ref = Process.monitor(inference)
    assert :ok = AudioFlow.cancel(session)
    assert_receive {AudioFlow, ^session, ^turn, {:cancelled, _}}
    assert_receive {:DOWN, ^ref, :process, ^inference, :killed}

    {:ok, next} = AudioFlow.submit(session, audio)
    assert_receive {:inference, next_inference}
    send(next_inference, :continue)
    assert_receive {AudioFlow, ^session, ^next, {:text, "A reply."}}
    assert_receive {AudioFlow, ^session, ^next, {:done, _}}
  end

  test "both worker and client deadlines stop inference and restore capacity" do
    owner = self()

    for {worker_timeout, client_timeout} <- [{50, 2_000}, {2_000, 50}] do
      worker =
        worker(
          fn
            :block, _ ->
              send(owner, {:inference, self()})

              receive do
                :continue -> :ok
              end

            :ready, emit ->
              emit.("Ready.")
          end,
          timeout_ms: worker_timeout
        )

      task =
        Task.async(fn ->
          Worker.run(:block, [worker: worker, timeout_ms: client_timeout], fn _ -> :ok end)
        end)

      assert_receive {:inference, inference}
      ref = Process.monitor(inference)
      assert {:error, :worker_timeout} = Task.await(task)
      assert_receive {:DOWN, ^ref, :process, ^inference, :killed}
      assert :ok = Worker.run(:ready, [worker: worker], fn "Ready." -> :ok end)
    end
  end

  test "a killed worker stops its inference task and reports its exit to the client" do
    owner = self()

    worker =
      worker(fn _, emit ->
        send(owner, {:inference, self()})
        emit.(:ready)

        receive do
          :continue -> :ok
        end
      end)

    task =
      Task.async(fn ->
        Worker.run(:block, [worker: worker], fn :ready ->
          send(owner, :admitted)
          :ok
        end)
      end)

    assert_receive {:inference, inference}
    assert_receive :admitted
    ref = Process.monitor(inference)
    Process.exit(worker, :kill)
    assert {:error, {:worker_exit, :killed}} = Task.await(task)
    assert_receive {:DOWN, ^ref, :process, ^inference, :killed}
  end
end
