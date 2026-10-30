defmodule AudioFlow.DistributedWorkerTest do
  use ExUnit.Case, async: false
  alias AudioFlow.{Audio, Router, Worker}
  @moduletag :distributed

  setup do
    assert Node.alive?(), "start the test with elixir --sname audioflow_test -S mix test"

    {:ok, peer, node} =
      :peer.start(%{
        name: :"audioflow_worker_#{System.unique_integer([:positive])}",
        connection: :standard_io,
        args:
          [~c"+S", ~c"2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie()), ~c"-pa"] ++
            :code.get_path()
      })

    on_exit(fn ->
      if Process.alive?(peer), do: :peer.stop(peer)
    end)

    assert Node.connect(node)

    :ok =
      :peer.call(peer, Application, :put_env, [
        :audio_flow,
        :inference_children,
        [
          {Worker,
           name: AudioFlow.RemoteTestWorker,
           adapter: {AudioFlow.Test.DistributedAdapter, owner: self()}}
        ]
      ])

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:audio_flow])
    %{peer: peer, node: node, worker: {AudioFlow.RemoteTestWorker, node}}
  end

  test "session cancellation crosses the node and releases the remote worker", context do
    router = start_supervised!({Router, routes: %{chat: [context.worker]}})

    {:ok, session} =
      AudioFlow.start_session(
        Keyword.put(
          AudioFlow.Adapters.Demo.options(),
          :llm,
          {Router, router: router, route: :chat}
        )
      )

    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    audio = %Audio{data: <<0, 0>>, sample_rate: 16_000}
    {:ok, first} = AudioFlow.submit(session, audio)
    assert_receive {:remote_inference, inference, "Hello"}
    assert node(inference) == context.node
    assert_receive {AudioFlow, ^session, ^first, {:text, "Working."}}
    ref = Process.monitor(inference)
    assert :ok = AudioFlow.cancel(session)
    assert_receive {AudioFlow, ^session, ^first, {:cancelled, _}}
    assert_receive {:DOWN, ^ref, :process, ^inference, :killed}

    {:ok, second} = AudioFlow.submit(session, audio)
    assert_receive {:remote_inference, next, "Hello"}
    assert node(next) == context.node
    send(next, :continue)
    expected = "Reply from #{context.node}."
    assert_receive {AudioFlow, ^session, ^second, {:text, ^expected}}
    assert_receive {AudioFlow, ^session, ^second, {:audio, %Audio{}}}
    assert_receive {AudioFlow, ^session, ^second, {:done, _}}
  end

  test "node loss ends accepted work and later requests use an available worker", context do
    owner = self()

    task =
      Task.async(fn ->
        Worker.run("Hello", [worker: context.worker], fn "Working." ->
          send(owner, :admitted)
          :ok
        end)
      end)

    assert_receive {:remote_inference, inference, "Hello"}
    assert node(inference) == context.node
    assert_receive :admitted
    :ok = :peer.stop(context.peer)
    assert {:error, {:worker_exit, :noconnection}} = Task.await(task)

    fallback =
      start_supervised!(
        {Worker, adapter: {AudioFlow.Adapters.Function, run: fn input, emit -> emit.(input) end}}
      )

    router = start_supervised!({Router, routes: %{chat: [context.worker, fallback]}})

    assert :ok =
             Router.run("Fallback.", [router: router, route: :chat], fn "Fallback." -> :ok end)
  end
end
