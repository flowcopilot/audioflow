defmodule AudioFlow.HotUpgradeTest do
  # Reloads shared modules, so other tests must not run at the same time.
  use ExUnit.Case, async: false
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Adapters.Function
  alias AudioFlow.Audio
  alias AudioFlow.Worker

  # Loads the current object code again, so the VM holds an old and a current
  # version, as after a release_handler `load_module` instruction.
  defp reload(module) do
    {^module, binary, file} = :code.get_object_code(module)
    {:module, ^module} = :code.load_binary(module, file, binary)
  end

  # The sequence that an appup `{:update, module, {:advanced, []}}` runs.
  defp upgrade(pid, module) do
    :ok = :sys.suspend(pid)
    reload(module)
    :ok = :sys.change_code(pid, module, 1, [])
    :ok = :sys.resume(pid)
  end

  defp blocking(test) do
    fn input, emit ->
      send(test, {:blocked, self()})

      receive do
        :go -> emit.(input)
      end
    end
  end

  test "a session finishes a turn that was running during the upgrade and keeps history" do
    test = self()

    options =
      Demo.options()
      |> Keyword.merge(
        history: true,
        stt: {Function, run: fn _, emit -> emit.("u1") end},
        llm:
          {Function,
           run: fn messages, emit ->
             send(test, {:prompt, messages})
             blocking(test).("reply", emit)
           end}
      )

    {:ok, session} = AudioFlow.start_session(Keyword.put(options, :owner, test))
    {:ok, turn} = AudioFlow.submit(session, %Audio{data: <<0, 0>>, sample_rate: 16_000})
    assert_receive {:blocked, task}
    task_ref = Process.monitor(task)

    upgrade(session, AudioFlow.Session)
    send(task, :go)
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}, 1000

    # The turn task ran the old code and has exited; the session runs the new
    # code. (A global :code.soft_purge/1 would also see processes that other
    # test modules leave behind.)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}
    refute :erlang.check_process_code(session, AudioFlow.Session)

    {:ok, next} = AudioFlow.submit(session, %Audio{data: <<0, 0>>, sample_rate: 16_000})
    assert_receive {:prompt, [%{content: "u1"}, %{content: "reply"}, %{content: "u1"}]}
    assert_receive {:blocked, task}
    send(task, :go)
    assert_receive {AudioFlow, ^session, ^next, {:done, _}}, 1000
  end

  test "a worker returns a request that was running during the upgrade" do
    test = self()
    {:ok, worker} = Worker.start_link(adapter: {Function, run: blocking(test)})

    caller =
      Task.async(fn ->
        Worker.run("in", [worker: worker], fn out ->
          send(test, {:out, out})
          :ok
        end)
      end)

    assert_receive {:blocked, task}
    task_ref = Process.monitor(task)
    upgrade(worker, Worker)
    send(task, :go)
    assert_receive {:out, "in"}, 1000
    assert :ok = Task.await(caller)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}
    refute :erlang.check_process_code(worker, Worker)
  end
end
