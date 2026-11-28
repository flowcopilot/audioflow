defmodule AudioFlow.PacketWorkerTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Audio
  alias AudioFlow.PacketWorker
  alias AudioFlow.SmartTurn

  @script Path.expand("fixtures/packet_worker.escript", __DIR__)

  @moduletag capture_log: true
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    log = Path.join(dir, "worker.log")

    {:ok, worker} =
      PacketWorker.start_link(executable: System.find_executable("escript"), args: [@script, log])

    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)
    {:ok, worker: worker, log: log}
  end

  defp lines(log), do: log |> File.read!() |> String.split("\n", trim: true)
  defp starts(log), do: Enum.count(lines(log), &(&1 == "start"))

  test "serves requests in order", %{worker: worker} do
    assert {:ok, "echo 1"} = PacketWorker.request(worker, "echo 1", 1000)
    assert {:ok, "echo 2"} = PacketWorker.request(worker, "echo 2", 1000)
  end

  test "a slow request times out, its late reply is dropped and the worker keeps its program",
       %{worker: worker, log: log} do
    assert {:error, :timeout} = PacketWorker.request(worker, "slow:300", 100)
    assert {:ok, "echo after"} = PacketWorker.request(worker, "echo after", 1500)
    assert Process.alive?(worker)
    assert starts(log) == 1
  end

  test "a late reply that arrives while the worker is idle settles the timed-out request",
       %{worker: worker, log: log} do
    assert {:error, :timeout} = PacketWorker.request(worker, "slow:150", 50)
    # The late "slow" reply reaches the idle worker before the next request.
    Process.sleep(300)
    assert {:ok, "echo next"} = PacketWorker.request(worker, "echo next", 1000)
    assert {:ok, "echo last"} = PacketWorker.request(worker, "echo last", 1000)
    assert starts(log) == 1
  end

  test "a hung program is replaced inside the same worker process", %{worker: worker, log: log} do
    assert {:error, :timeout} = PacketWorker.request(worker, "hang", 100)
    assert {:error, :timeout} = PacketWorker.request(worker, "echo blocked", 100)
    assert {:ok, "echo recovered"} = PacketWorker.request(worker, "echo recovered", 5000)
    assert Process.alive?(worker)
    assert starts(log) == 2
  end

  test "a crashed program is restarted", %{worker: worker, log: log} do
    assert {:error, {:worker_exit, 3}} = PacketWorker.request(worker, "die", 2000)
    assert {:ok, "echo again"} = PacketWorker.request(worker, "echo again", 5000)
    assert Process.alive?(worker)
    assert starts(log) == 2
  end

  test "stray messages do not stop the worker", %{worker: worker} do
    send(worker, :unexpected)
    send(worker, {make_ref(), {:data, "late"}})
    assert {:ok, "echo ok"} = PacketWorker.request(worker, "echo ok", 1000)
  end

  test "queued requests whose deadline passed never reach the program", %{
    worker: worker,
    log: log
  } do
    busy = Task.async(fn -> PacketWorker.request(worker, "slow:400", 2000) end)
    Process.sleep(100)

    assert {:error, :timeout} = PacketWorker.request(worker, "echo expired", 50)
    assert {:ok, "slow"} = Task.await(busy)
    assert {:ok, "echo live"} = PacketWorker.request(worker, "echo live", 1000)

    received = lines(log)
    assert "recv:echo live" in received
    refute "recv:echo expired" in received
  end

  test "queued requests whose caller died never reach the program", %{worker: worker, log: log} do
    busy = Task.async(fn -> PacketWorker.request(worker, "slow:400", 2000) end)
    Process.sleep(100)
    {pid, monitor} = spawn_monitor(fn -> PacketWorker.request(worker, "echo orphan", 2000) end)
    Process.sleep(50)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:ok, "slow"} = Task.await(busy)
    assert {:ok, "echo live"} = PacketWorker.request(worker, "echo live", 1000)

    refute "recv:echo orphan" in lines(log)
  end

  test "one worker serves several streams without cross-talk", %{worker: worker} do
    results =
      1..6
      |> Enum.map(fn i ->
        Task.async(fn -> PacketWorker.request(worker, "echo #{i}", 2000) end)
      end)
      |> Task.await_many()

    assert results == for(i <- 1..6, do: {:ok, "echo #{i}"})
  end

  test "Smart Turn recovers after a slow inference", %{worker: worker} do
    pcm = fn prefix -> prefix <> :binary.copy(<<0>>, 64) end
    slow = %Audio{data: pcm.("slow:700"), sample_rate: 16_000}
    fast = %Audio{data: pcm.("prob"), sample_rate: 16_000}

    assert_raise RuntimeError, fn -> SmartTurn.predict(slow, worker) end
    assert SmartTurn.predict(fast, worker) == 0.75
  end
end
