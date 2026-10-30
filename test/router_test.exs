defmodule AudioFlow.RouterTest do
  use ExUnit.Case, async: true
  alias AudioFlow.{Adapters.Function, Audio, Router, Worker}

  defp worker(run) do
    start_supervised!(
      Supervisor.child_spec({Worker, adapter: {Function, run: run}}, id: make_ref())
    )
  end

  test "a long-lived session uses round-robin workers and accepts route changes" do
    first = worker(fn text, emit -> emit.("First: #{text}.") end)
    second = worker(fn text, emit -> emit.("Second: #{text}.") end)
    router = start_supervised!({Router, routes: %{chat: [first, second]}})

    {:ok, session} =
      AudioFlow.start_session(
        Keyword.put(
          AudioFlow.Adapters.Demo.options(),
          :llm,
          {Router, router: router, route: fn "Hello" -> :chat end}
        )
      )

    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    audio = %Audio{data: <<0, 0>>, sample_rate: 16_000}

    for expected <- ["First: Hello.", "Second: Hello."] do
      {:ok, turn} = AudioFlow.submit(session, audio)
      assert_receive {AudioFlow, ^session, ^turn, {:text, ^expected}}
      assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
    end

    assert :ok = Router.put_route(router, :chat, [second])
    {:ok, turn} = AudioFlow.submit(session, audio)
    assert_receive {AudioFlow, ^session, ^turn, {:text, "Second: Hello."}}
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
  end

  test "busy and unavailable workers are skipped before admission" do
    owner = self()

    busy =
      worker(fn _, _ ->
        send(owner, :occupied)

        receive do
          :continue -> :ok
        end
      end)

    unavailable = spawn(fn -> :ok end)
    ref = Process.monitor(unavailable)
    assert_receive {:DOWN, ^ref, :process, ^unavailable, _}
    fallback = worker(fn input, emit -> emit.(input) end)
    task = Task.async(fn -> Worker.run(:hold, [worker: busy], fn _ -> :ok end) end)
    assert_receive :occupied
    router = start_supervised!({Router, routes: %{chat: [busy, unavailable, fallback]}})

    assert :ok =
             Router.run("Fallback.", [router: router, route: :chat], fn "Fallback." -> :ok end)

    Task.shutdown(task, :brutal_kill)
  end

  test "an accepted request error does not replay partial output on a fallback worker" do
    owner = self()

    first =
      worker(fn _, emit ->
        emit.("Partial reply.")
        {:error, :model_error}
      end)

    fallback = worker(fn _, emit -> emit.("Fallback reply.") end)
    router = start_supervised!({Router, routes: %{chat: [first, fallback]}})

    assert {:error, {:adapter_error, Function, :model_error}} =
             Router.run("Hello", [router: router, route: :chat], fn output ->
               send(owner, {:output, output})
               :ok
             end)

    assert_receive {:output, "Partial reply."}
    refute_receive {:output, "Fallback reply."}, 20
  end

  test "unknown, disabled, and exhausted routes return explicit errors" do
    unavailable = spawn(fn -> :ok end)
    ref = Process.monitor(unavailable)
    assert_receive {:DOWN, ^ref, :process, ^unavailable, _}
    router = start_supervised!({Router, routes: %{disabled: [], offline: [unavailable]}})

    assert {:error, {:unknown_route, :missing}} =
             Router.run("Hello", [router: router, route: :missing], fn _ -> :ok end)

    assert {:error, {:no_worker_available, :disabled, []}} =
             Router.run("Hello", [router: router, route: :disabled], fn _ -> :ok end)

    assert {:error,
            {:no_worker_available, :offline, [{^unavailable, {:worker_unavailable, :noproc}}]}} =
             Router.run("Hello", [router: router, route: :offline], fn _ -> :ok end)
  end
end
