defmodule AudioFlow.BenchmarkTest do
  use ExUnit.Case, async: false
  alias AudioFlow.{Audio, Benchmark}
  defp audio, do: %Audio{data: <<0, 0>>, sample_rate: 16000}

  test "warmups and measured attempts are retained at the selected concurrency" do
    rows = Benchmark.run(AudioFlow.Adapters.Demo.options(), audio(), 5, 3, warmup: 2)

    assert Enum.map(rows, &{&1.phase, &1.run}) == [
             {:warmup, 1},
             {:warmup, 2},
             {:measured, 1},
             {:measured, 2},
             {:measured, 3},
             {:measured, 4},
             {:measured, 5}
           ]

    assert Enum.all?(
             rows,
             &(&1.status == :ok and &1.concurrency == 3 and is_integer(&1.first_audio_us))
           )
  end

  test "rejected input produces one error row for each attempt" do
    options = Keyword.put(AudioFlow.Adapters.Demo.options(), :max_input_bytes, 1)
    rows = Benchmark.run(options, audio(), 3, 2)
    assert length(rows) == 3

    assert Enum.all?(
             rows,
             &(&1.status == {:error, {:submit, :input_too_large}} and &1.first_audio_us == nil)
           )
  end

  test "completion without audio is recorded as a voice benchmark failure" do
    options =
      Keyword.put(
        AudioFlow.Adapters.Demo.options(),
        :stt,
        {AudioFlow.Adapters.Function, run: fn _, emit -> emit.("") end}
      )

    assert [%{status: {:error, :no_audio}, first_audio_us: nil}] =
             Benchmark.run(options, audio(), 1, 1)
  end

  test "an abrupt session exit is recorded instead of waiting forever" do
    owner = self()

    options =
      Keyword.put(
        AudioFlow.Adapters.Demo.options(),
        :stt,
        {AudioFlow.Adapters.Function,
         run: fn _, _ ->
           send(owner, :ready)

           receive do
             :wait -> :ok
           end
         end}
      )

    task = Task.async(fn -> Benchmark.run(options, audio(), 1, 1, timeout_ms: 2000) end)
    assert_receive :ready
    [{_, session, _, _}] = DynamicSupervisor.which_children(AudioFlow.Sessions)
    Process.exit(session, :kill)
    assert [%{status: {:error, {:session_exit, :killed}}}] = Task.await(task, 3000)
  end

  test "benchmark deadline stops a stalled turn and cleans up its inference worker" do
    owner = self()

    options =
      Keyword.put(
        AudioFlow.Adapters.Demo.options(),
        :stt,
        {AudioFlow.Adapters.Function,
         run: fn _, _ ->
           send(owner, {:worker, self()})

           receive do
             :wait -> :ok
           end
         end}
      )

    task = Task.async(fn -> Benchmark.run(options, audio(), 1, 1, timeout_ms: 100) end)
    assert_receive {:worker, worker}
    ref = Process.monitor(worker)
    assert [%{status: {:error, :benchmark_timeout}}] = Task.await(task, 3000)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
  end
end
