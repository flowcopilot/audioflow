if System.get_env("AUDIOFLOW_SFU") == "1" do
  defmodule AudioFlow.CallsTest do
    use ExUnit.Case, async: false
    alias AudioFlow.Calls.Call
    alias AudioFlow.CallStore
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

      {:ok, call} =
        CallStore.create(store, %{
          room: "room",
          agent: "Elixir.AudioFlow.Test.CallAgent",
          metadata: %{"test" => self(), "others" => [@user]}
        })

      {:ok, [call]} = CallStore.claim(store, "node-a", 60_000, 10)
      %{store: store, call: call}
    end

    defp start(store, call) do
      # A call stops with a shutdown reason; the test must not stop with it.
      Process.flag(:trap_exit, true)
      {:ok, pid} = Call.start_link(store: store, call: call, owner: "node-a")
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

    test "a call that lost its lease stops at its next save", %{store: store, call: call} do
      {pid, participant, agent} = start(store, call)
      await_saved(store, call.id, &(&1.resume_token == "token"))
      ref = Process.monitor(pid)
      :ok = CallStore.release(store, call.id, "node-a")
      {:ok, [_]} = CallStore.claim(store, "node-b", 60_000, 10)

      speak(agent, participant, 100)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :lease_lost}}, 3000
    end

    test "a call ends when the last user leaves", %{store: store, call: call} do
      {pid, participant, agent} = start(store, call)
      ref = Process.monitor(pid)
      send(agent, {:audio_flow_sfu, 1, participant, {:participant_left, @user}})
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :room_empty}}, 2000
      assert {:ok, %{status: :ended}} = CallStore.get(store, call.id)
    end
  end
end
