defmodule AudioFlowReleases.DurableCallTest do
  # Agents run on peer nodes; the SFU, the call store and the user run here.
  use ExUnit.Case, async: false
  import AudioFlowSFU.MediaAssertions
  alias AudioFlow.CallStore
  alias AudioFlowReleases.CallAgent
  alias AudioFlowReleases.Opus
  alias AudioFlowSFU.TestClient

  @lease_ms 1_000

  setup do
    {:ok, store} = CallStore.Memory.start_link()
    room = "durable-#{System.unique_integer([:positive])}"
    {:ok, user} = TestClient.start(room, "user")
    connected(user)
    assert_receive {:client, ^user, {:track_published, _}}, 5000
    %{store: {CallStore.Memory, store}, room: room, user: user}
  end

  defp agent_node(name, store, options \\ []) do
    {:ok, peer, node} =
      :peer.start(%{
        name: :"#{name}_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie()), ~c"-pa" | :code.get_path()]
      })

    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
    true = Node.connect(node)

    calls =
      Keyword.merge(
        [store: store, sfu: node(), owner: name, lease_ms: @lease_ms, drain_timeout_ms: 2_000],
        options
      )

    :ok = :peer.call(peer, Application, :put_env, [:audio_flow, :calls, calls])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:audio_flow])
    {peer, node}
  end

  defp create_call(store, room, metadata \\ %{}) do
    {:ok, call} =
      CallStore.create(store, %{
        room: room,
        agent: Atom.to_string(CallAgent),
        metadata: Map.merge(%{"test" => self()}, metadata)
      })

    call
  end

  defp speak(user), do: for(payload <- Opus.frames(15, 15), do: TestClient.send_audio(user, payload))

  # The agent joins, then publishes its track in an update.
  defp agent_joined(user) do
    assert_receive {:client, ^user, {:participant_joined, %{kind: :agent, sid: sid}}}, 5000

    assert_receive {:client, ^user,
                    {:participant_updated, %{sid: ^sid, tracks: [%{sid: track}]}}},
                   5000

    await_offer(user, &(track in Map.values(&1)))
    sid
  end

  defp await_state(user, sid, state, timeout) do
    assert_receive {:client, ^user, {:participant_updated, %{sid: ^sid, state: ^state}}}, timeout
  end

  test "a crashed agent node's call moves to another node with its history",
       %{store: store, room: room, user: user} do
    {peer_a, node_a} = agent_node("agent_a", store)
    call = create_call(store, room)
    sid = agent_joined(user)
    participant = TestClient.participant(user)

    speak(user)
    assert_receive {:prompt, ^node_a, ["hello"]}, 5000
    await_saved(store, call.id, &(&1.history == [{"hello", "reply 1"}]))

    started = System.monotonic_time(:millisecond)
    :peer.stop(peer_a)
    await_state(user, sid, :away, 5000)

    {_peer_b, node_b} = agent_node("agent_b", store)
    await_state(user, sid, :active, @lease_ms + 5_000)
    moved = System.monotonic_time(:millisecond) - started
    assert moved < @lease_ms + 3_000

    # The same user connection, and the agent remembers the first turn.
    assert TestClient.participant(user) == participant
    assert {:ok, %{lease_owner: "agent_b"}} = CallStore.get(store, call.id)
    speak(user)
    assert_receive {:prompt, ^node_b, ["hello", "reply 1", "hello"]}, 5000
    refute_received {:client, ^user, {:participant_left, %{sid: ^sid}}}
  end

  test "a drained node hands its call over before the lease would expire",
       %{store: store, room: room, user: user} do
    {peer_a, _node_a} = agent_node("agent_a", store)
    call = create_call(store, room)
    sid = agent_joined(user)
    {_peer_b, node_b} = agent_node("agent_b", store)

    started = System.monotonic_time(:millisecond)
    :ok = :peer.call(peer_a, Application, :stop, [:audio_flow], 30_000)
    await_state(user, sid, :active, 5_000)
    assert System.monotonic_time(:millisecond) - started < @lease_ms + 1_000
    assert {:ok, %{lease_owner: "agent_b"}} = CallStore.get(store, call.id)

    speak(user)
    assert_receive {:prompt, ^node_b, ["hello"]}, 5000
  end

  test "by default, the input of a turn that a crash interrupted is dropped",
       %{store: store, room: room, user: user} do
    {peer_a, node_a} = agent_node("agent_a", store)
    call = create_call(store, room, %{"block_on" => node_a})
    sid = agent_joined(user)

    speak(user)
    assert_receive {:prompt, ^node_a, ["hello"]}, 5000
    :peer.stop(peer_a)

    {_peer_b, node_b} = agent_node("agent_b", store)
    await_state(user, sid, :active, @lease_ms + 5_000)
    refute_receive {:prompt, ^node_b, _}, 1_000
    assert {:ok, %{history: [], pending_input: nil}} = CallStore.get(store, call.id)
  end

  test "retry_input submits the input of a turn that a crash interrupted",
       %{store: store, room: room, user: user} do
    {peer_a, node_a} = agent_node("agent_a", store, interrupted_turn: :retry_input)
    call = create_call(store, room, %{"block_on" => node_a})
    sid = agent_joined(user)

    speak(user)
    assert_receive {:prompt, ^node_a, ["hello"]}, 5000
    await_saved(store, call.id, &(&1.pending_input != nil))
    :peer.stop(peer_a)

    {_peer_b, node_b} = agent_node("agent_b", store, interrupted_turn: :retry_input)
    await_state(user, sid, :active, @lease_ms + 5_000)
    assert_receive {:prompt, ^node_b, ["hello"]}, 5000
    await_saved(store, call.id, &(&1.pending_input == nil and &1.history != []))
  end

  defp await_saved(store, id, check, attempts \\ 150) do
    {:ok, call} = CallStore.get(store, id)

    cond do
      check.(call) -> call
      attempts == 0 -> flunk("not saved: #{inspect(Map.drop(call, [:metadata]))}")
      true -> Process.sleep(20) && await_saved(store, id, check, attempts - 1)
    end
  end
end
