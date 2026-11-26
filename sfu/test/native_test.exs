defmodule AudioFlowSFU.NativeTest do
  use ExUnit.Case, async: false
  import AudioFlowSFU.MediaAssertions
  alias AudioFlowSFU.Native
  alias AudioFlowSFU.Room
  alias AudioFlowSFU.TestAgent
  alias AudioFlowSFU.TestClient

  defp room, do: "native-#{System.unique_integer([:positive])}"

  defp peer do
    {:ok, peer, node} =
      :peer.start(%{
        name: :"agent_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie()), ~c"-pa" | :code.get_path()]
      })

    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
    true = Node.connect(node)
    {peer, node}
  end

  # The agent runs on another node and joins through :erpc, as AudioFlow does.
  defp remote_agent(node, name, options \\ []) do
    agent = :erpc.call(node, TestAgent, :start, [self()])
    {:ok, join} = :erpc.call(node(), Native, :join, [name, "agent", agent, options])
    {agent, join}
  end

  defp agent_audio(agent, timeout \\ 5000) do
    assert_receive {:agent, ^agent, {:audio_flow_sfu, 1, _, {:rtp, _, %{payload: payload}}}},
                   timeout

    payload
  end

  # Sends agent audio until the client gets one packet.
  defp assert_agent_heard(agent, participant, track, client) do
    Enum.reduce_while(1..250, nil, fn n, _ ->
      TestAgent.send_rtp(agent, participant, track, n, payload(rem(n, 256)))

      receive do
        {:client, ^client, {:rtp, _}} -> {:halt, :ok}
      after
        20 -> {:cont, nil}
      end
    end)
    |> case do
      :ok -> :ok
      nil -> flunk("the client did not hear the agent")
    end
  end

  test "an agent on another node hears a client and is heard by another client" do
    {_peer, node} = peer()
    name = room()
    {:ok, alice} = TestClient.start(name, "alice")
    connected(alice)

    {agent, join} = remote_agent(node, name)
    assert node(agent) == node
    assert %{info: %{kind: :agent, sid: "PA_" <> _}, others: [%{identity: "alice"}]} = join

    for n <- 1..100, do: TestClient.send_audio(alice, payload(n))
    assert byte_size(agent_audio(agent)) == 60

    {:ok, track} = :erpc.call(node, Native, :publish_track, [join.participant])
    {:ok, bob} = TestClient.start(name, "bob", can_publish: false)
    connected(bob)
    await_offer(bob, &(track.sid in Map.values(&1)))
    assert_agent_heard(agent, join.participant, track.sid, bob)
  end

  test "an agent node that stops leaves an away participant that a new agent takes back" do
    {peer, node} = peer()
    name = room()
    {:ok, bob} = TestClient.start(name, "bob", can_publish: false)
    connected(bob)
    {_agent, join} = remote_agent(node, name)
    {:ok, track} = Native.publish_track(join.participant)
    %{sid: sid} = join.info

    :peer.stop(peer)

    assert_receive {:client, ^bob, {:participant_updated, %{sid: ^sid, state: :away}}}, 5000
    assert Enum.any?(Room.participants(Room.whereis(name)), &(&1.sid == sid))

    # A new agent, here on the SFU node, resumes the same participant.
    agent = TestAgent.start(self())

    assert {:ok, %{participant: participant, info: %{sid: ^sid, state: :active}}} =
             Native.join(name, "agent", agent, resume_token: join.resume_token)

    assert participant == join.participant
    assert_receive {:client, ^bob, {:participant_updated, %{sid: ^sid, state: :active}}}, 5000
    await_offer(bob, &(track.sid in Map.values(&1)))
    assert_agent_heard(agent, participant, track.sid, bob)
    refute_received {:client, ^bob, {:participant_left, %{sid: ^sid}}}
  end

  test "an away agent that is not resumed leaves after the timeout" do
    name = room()
    {:ok, bob} = TestClient.start(name, "bob", can_publish: false)
    agent = TestAgent.start(self())
    {:ok, join} = Native.join(name, "agent", agent, away_timeout_ms: 100)
    Process.exit(agent, :kill)
    %{sid: sid} = join.info
    assert_receive {:client, ^bob, {:participant_left, %{sid: ^sid}}}, 2000

    assert {:error, :unknown_session} =
             Native.join(name, "agent", self(), resume_token: join.resume_token)
  end
end
