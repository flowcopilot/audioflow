if System.get_env("AUDIOFLOW_SFU") == "1" do
  defmodule AudioFlow.CallsTest do
    use ExUnit.Case, async: false
    alias AudioFlow.Calls
    alias AudioFlow.Calls.Call
    alias AudioFlow.CallStore
    alias AudioFlow.Test.CallFlakyStore
    alias Membrane.Opus.Encoder.Native, as: Encoder

    @user %{
      sid: "PA_user",
      identity: "user",
      kind: :standard,
      joined_at: 1,
      tracks: [%{sid: "TR_user", mime_type: "audio/opus", name: "microphone"}]
    }

    setup do
      {:ok, pid} = CallStore.Memory.start_link()
      store = {CallStore.Memory, pid}

      {:ok, _} =
        CallStore.create(store, %{
          room: "room",
          agent: "Elixir.AudioFlow.Test.CallAgent",
          metadata: %{"test" => self(), "others" => [@user]}
        })

      {:ok, [call]} = CallStore.claim(store, "node-a", 60_000, 10)
      %{store: store, call: call}
    end

    defp start(store, call, options \\ []) do
      # A call stops with a shutdown reason; the test must not stop with it.
      Process.flag(:trap_exit, true)
      {:ok, pid} = Call.start_link([store: store, call: call, owner: "node-a"] ++ options)
      assert_receive {:sfu_join, participant, agent, _}
      {pid, participant, agent}
    end

    defp speak(agent, participant, first_sequence) do
      encoder = Encoder.create(48_000, 1, 2048, -1000, 3001)

      tone =
        for i <- 0..959,
            into: <<>>,
            do: <<round(:math.sin(i / 48 * :math.pi()) * 12_000)::little-signed-16>>

      for {pcm, n} <-
            Enum.with_index(List.duplicate(tone, 10) ++ List.duplicate(<<0::15_360>>, 10)) do
        {:ok, payload} = Encoder.encode_packet(encoder, pcm, 960)

        rtp = %{
          sequence_number: first_sequence + n,
          timestamp: n * 960,
          marker: false,
          payload: payload
        }

        send(agent, {:audio_flow_sfu, 1, participant, {:rtp, "TR_user", rtp}})
      end
    end

    defp await_saved(store, id, check, attempts \\ 100) do
      {:ok, call} = CallStore.get(store, id)

      cond do
        check.(call) -> call
        attempts == 0 -> flunk("not saved: #{inspect(call)}")
        true -> Process.sleep(20) && await_saved(store, id, check, attempts - 1)
      end
    end

    test "a call saves its resume token and each committed turn", %{store: store, call: call} do
      {_pid, participant, agent} = start(store, call)
      await_saved(store, call.id, &(&1.resume_token == "token"))

      speak(agent, participant, 100)
      assert_receive {:prompt, [%{content: "hello"}]}, 2000
      saved = await_saved(store, call.id, &(&1.history != []))
      assert saved.history == [{"hello", "reply 1"}] and saved.turns == 1
    end

    # Loads a changed version of the Call module, as a hot upgrade does. A second
    # load removes the code of the first one, so a fun made by it breaks.
    defp upgrade(pid, version) do
      source =
        "lib_sfu/audio_flow/calls/call.ex"
        |> File.read!()
        |> String.replace("@vsn 1\n", "@vsn 1\n  def version, do: #{version}\n")

      :ok = :sys.suspend(pid)
      Code.put_compiler_option(:ignore_module_conflict, true)
      Code.compile_string(source)
      Code.put_compiler_option(:ignore_module_conflict, false)
      :ok = :sys.change_code(pid, Call, 1, [])
      :ok = :sys.resume(pid)
    end

    test "a call keeps saving after two code loads of its module", %{store: store, call: call} do
      {original, binary, file} = :code.get_object_code(Call)

      on_exit(fn -> :code.purge(original) && :code.load_binary(original, file, binary) end)
      {pid, participant, agent} = start(store, call)
      await_saved(store, call.id, &(&1.resume_token == "token"))

      upgrade(pid, 2)
      upgrade(pid, 3)

      speak(agent, participant, 100)
      saved = await_saved(store, call.id, &(&1.history != []))
      assert saved.history == [{"hello", "reply 1"}]
    end

    test "a call restarts from the saved history", %{store: store, call: call} do
      {:ok, call} =
        CallStore.save(store, call.id, "node-a", call.version, %{
          history: [{"earlier", "answer"}],
          turns: 1
        })

      {_pid, participant, agent} = start(store, call)
      speak(agent, participant, 100)

      assert_receive {:prompt,
                      [%{content: "earlier"}, %{content: "answer"}, %{content: "hello"}]},
                     2000
    end

    test "a call whose SFU participant timed out joins as a new participant",
         %{store: store, call: call} do
      {:ok, call} =
        CallStore.save(store, call.id, "node-a", call.version, %{resume_token: "expired"})

      {_pid, _participant, _agent} = start(store, call)
      await_saved(store, call.id, &(&1.resume_token == "token"))
    end

    test "a call that lost its lease stops at its next save", %{store: store, call: call} do
      {pid, participant, agent} = start(store, call)
      await_saved(store, call.id, &(&1.resume_token == "token"))
      ref = Process.monitor(pid)
      :ok = CallStore.release(store, call.id, "node-a")
      {:ok, [_]} = CallStore.claim(store, "node-b", 60_000, 10)

      speak(agent, participant, 100)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :lease_lost}}, 3000
    end

    test "a call whose room has no user ends after the empty timeout", %{store: store} do
      {:ok, _} =
        CallStore.create(store, %{
          room: "empty",
          agent: "Elixir.AudioFlow.Test.CallAgent",
          metadata: %{"test" => self(), "others" => []}
        })

      {:ok, [call]} = CallStore.claim(store, "node-a", 60_000, 10)
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Call.start_link(store: store, call: call, owner: "node-a", empty_timeout_ms: 100)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :room_empty}}, 2000
      assert {:ok, %{status: :ended}} = CallStore.get(store, call.id)
    end

    test "a call ends when the last user leaves and does not return", %{store: store, call: call} do
      {pid, participant, agent} = start(store, call, leave_grace_ms: 50)
      ref = Process.monitor(pid)
      send(agent, {:audio_flow_sfu, 1, participant, {:participant_left, @user}})
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :room_empty}}, 2000
      assert {:ok, %{status: :ended}} = CallStore.get(store, call.id)
    end

    test "a call keeps going when its user leaves and joins again", %{store: store, call: call} do
      {pid, participant, agent} = start(store, call, leave_grace_ms: 300)
      ref = Process.monitor(pid)
      await_saved(store, call.id, &(&1.resume_token == "token"))

      # A page reload with the same identity: the SFU sends left, then joined.
      send(agent, {:audio_flow_sfu, 1, participant, {:participant_left, @user}})
      send(agent, {:audio_flow_sfu, 1, participant, {:participant_joined, @user}})
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 600
      assert {:ok, %{status: :active}} = CallStore.get(store, call.id)
    end

    test "a drain saves the commit of the turn that it waited for", %{store: store} do
      {:ok, _} =
        CallStore.create(store, %{
          room: "hold",
          agent: "Elixir.AudioFlow.Test.CallAgent",
          metadata: %{"test" => self(), "others" => [@user], "hold" => true}
        })

      {:ok, calls} = CallStore.claim(store, "node-a", 60_000, 10)
      call = Enum.find(calls, &(&1.room == "hold"))
      {pid, participant, agent} = start(store, call)
      await_saved(store, call.id, &(&1.resume_token == "token"))

      speak(agent, participant, 100)
      assert_receive {:llm_blocked, turn}, 2000
      drain = Task.async(fn -> Call.drain(pid, 5_000) end)
      refute Task.yield(drain, 100)
      send(turn, :go)

      assert :ok = Task.await(drain)
      assert {:ok, %{history: [{"hello", "reply 1"}], turns: 1}} = CallStore.get(store, call.id)
      # The lease ended with the drain: another node claims the call at once.
      assert {:ok, [%{id: id}]} = CallStore.claim(store, "node-b", 60_000, 10)
      assert id == call.id
    end

    test "a call keeps its newest snapshot while the store fails, and saves it later" do
      {:ok, memory} = CallStore.Memory.start_link()
      {:ok, flag} = Agent.start_link(fn -> :ok end)

      store =
        {CallFlakyStore, memory: {CallStore.Memory, memory}, flag: flag, test: self()}

      {:ok, _} =
        CallStore.create(store, %{
          room: "flaky",
          agent: "Elixir.AudioFlow.Test.CallAgent",
          metadata: %{"test" => self(), "others" => [@user]}
        })

      {:ok, [call]} = CallStore.claim(store, "node-a", 60_000, 10)
      {pid, participant, agent} = start(store, call)
      await_saved(store, call.id, &(&1.resume_token == "token"))

      CallFlakyStore.fail_with(store, {:error, :db_down})
      speak(agent, participant, 100)
      assert_receive {:save, %{history: _}}, 2000
      assert Process.alive?(pid)
      assert {:ok, %{history: []}} = CallStore.get(store, call.id)

      CallFlakyStore.fail_with(store, :ok)
      saved = await_saved(store, call.id, &(&1.history != []), 200)
      assert saved.history == [{"hello", "reply 1"}] and saved.turns == 1
      assert Process.alive?(pid)
    end

    test "a save sends the changed fields, and appends new history", %{call: call} do
      {:ok, memory} = CallStore.Memory.start_link()
      {:ok, flag} = Agent.start_link(fn -> :ok end)

      store =
        {CallFlakyStore, memory: {CallStore.Memory, memory}, flag: flag, test: self()}

      {:ok, _} = CallStore.create(store, Map.take(call, [:room, :agent, :metadata]))
      {:ok, [call]} = CallStore.claim(store, "node-a", 60_000, 10)

      {:ok, call} =
        CallStore.save(store, call.id, "node-a", call.version, %{
          history: [{"earlier", "answer"}],
          turns: 1
        })

      {_pid, participant, agent} = start(store, call)
      await_saved(store, call.id, &(&1.resume_token == "token"))
      assert_receive {:save, %{resume_token: "token"} = join_save}
      assert Map.keys(join_save) == [:resume_token]

      speak(agent, participant, 100)
      assert_receive {:save, %{history: {:append, [{"hello", "reply 3"}]}} = saved}, 2000
      assert saved == %{history: {:append, [{"hello", "reply 3"}]}, turns: 2}
    end

    test "a call starts without waiting for its SFU join", %{store: store} do
      {:ok, _} =
        CallStore.create(store, %{
          room: "slow",
          agent: "Elixir.AudioFlow.Test.CallAgent",
          metadata: %{"test" => self(), "others" => [@user], "join_delay" => 500}
        })

      {:ok, calls} = CallStore.claim(store, "node-a", 60_000, 10)
      call = Enum.find(calls, &(&1.room == "slow"))
      Process.flag(:trap_exit, true)

      {micros, {:ok, pid}} =
        :timer.tc(fn -> Call.start_link(store: store, call: call, owner: "node-a") end)

      assert micros < 200_000
      assert_receive {:sfu_join, _, _, _}, 2000
      assert Process.alive?(pid)
    end

    test "a call that cannot start stops and keeps its lease", %{store: store} do
      {:ok, _} = CallStore.create(store, %{room: "bad", agent: "Elixir.AudioFlow.NoSuchAgent"})
      {:ok, calls} = CallStore.claim(store, "node-a", 60_000, 10)
      call = Enum.find(calls, &(&1.room == "bad"))
      Process.flag(:trap_exit, true)
      {:ok, pid} = Call.start_link(store: store, call: call, owner: "node-a")
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:start_failed, _}}}, 2000
      assert {:ok, %{lease_owner: "node-a", status: :active}} = CallStore.get(store, call.id)
      # No node claims it before the lease expires: this is the back-off.
      {:ok, claimed} = CallStore.claim(store, "node-b", 60_000, 10)
      refute Enum.any?(claimed, &(&1.id == call.id))
    end

    describe "AudioFlow.Calls" do
      setup %{store: store} do
        start_supervised!(
          {Calls, store: store, owner: "node-a", lease_ms: 300, drain_timeout_ms: 3_000}
        )

        :ok
      end

      test "a drain keeps the leases and the claimer while a turn runs", %{store: store} do
        {:ok, %{id: id}} =
          Calls.start_call("room", AudioFlow.Test.CallAgent, %{
            "test" => self(),
            "others" => [@user],
            "hold" => true
          })

        assert_receive {:sfu_join, participant, agent, _}, 2000
        claimer = Process.whereis(Calls.Claimer)
        speak(agent, participant, 100)
        assert_receive {:llm_blocked, turn}, 2000

        drain = Task.async(&Calls.drain/0)
        # More than two lease lengths: only renewals keep the lease.
        Process.sleep(800)
        assert {:ok, claimed} = CallStore.claim(store, "node-b", 60_000, 10)
        refute Enum.any?(claimed, &(&1.id == id))

        send(turn, :go)
        assert :ok = Task.await(drain)
        assert Process.whereis(Calls.Claimer) == claimer
        assert {:ok, %{history: [{"hello", "reply 1"}]}} = CallStore.get(store, id)
      end

      test "a drain survives a call that exits, and the claimer does not claim again" do
        {:ok, %{id: id}} =
          Calls.start_call("room", AudioFlow.Test.CallAgent, %{
            "test" => self(),
            "others" => [@user],
            "hold" => true
          })

        assert_receive {:sfu_join, participant, agent, _}, 2000
        claimer = Process.whereis(Calls.Claimer)
        speak(agent, participant, 100)
        assert_receive {:llm_blocked, _turn}, 2000

        drain = Task.async(&Calls.drain/0)
        Process.sleep(100)
        Process.exit(Calls.whereis(id), :kill)

        assert :ok = Task.await(drain)
        assert Process.whereis(Calls.Claimer) == claimer
        # A draining node does not claim: its own call stays unclaimed here.
        Process.sleep(500)
        assert Calls.whereis(id) == nil
      end
    end
  end
end
