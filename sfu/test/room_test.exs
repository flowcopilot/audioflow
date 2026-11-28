defmodule AudioFlowSFU.RoomTest do
  # Some tests change the room limits in the application environment.
  use ExUnit.Case, async: false
  alias AudioFlowSFU.Participant.WebRTC
  alias AudioFlowSFU.Room
  alias AudioFlowSFU.TestClient
  import AudioFlowSFU.MediaAssertions

  defp room, do: "room-#{System.unique_integer([:positive])}"

  test "a published track reaches a participant that joins later" do
    name = room()
    {:ok, alice} = TestClient.start(name, "alice")
    connected(alice)
    assert_receive {:client, ^alice, {:track_published, %{sid: "TR_" <> _}}}, 5000

    {:ok, bob} = TestClient.start(name, "bob", can_publish: false)

    assert [%{identity: "alice", tracks: [%{mime_type: "audio/opus"}]}] =
             TestClient.join_info(bob).others

    connected(bob)
    assert_forwarded(alice, bob)
  end

  test "a participant that joined first gets a new track by renegotiation" do
    name = room()
    {:ok, bob} = TestClient.start(name, "bob", can_publish: false)
    connected(bob)

    {:ok, alice} = TestClient.start(name, "alice")
    assert_receive {:client, ^bob, {:participant_joined, %{identity: "alice"}}}, 5000
    connected(alice)

    assert_receive {:client, ^bob, {:participant_updated, %{tracks: [%{sid: track}]}}}, 5000
    await_offer(bob, &(track in Map.values(&1)))
    assert_forwarded(alice, bob)
  end

  test "a leaving publisher is removed from the room and its subscribers" do
    name = room()
    {:ok, alice} = TestClient.start(name, "alice")
    connected(alice)
    assert_receive {:client, ^alice, {:track_published, _}}, 5000
    {:ok, bob} = TestClient.start(name, "bob", can_publish: false)
    connected(bob)
    bob_participant = TestClient.participant(bob)

    :ok = WebRTC.leave(TestClient.participant(alice))
    assert_receive {:client, ^bob, {:participant_left, %{identity: "alice"}}}, 5000
    await_offer(bob, &(&1 == %{}))
    assert :sys.get_state(bob_participant).subscriptions == %{}
    assert [%{identity: "bob"}] = Room.participants(Room.whereis(name))
  end

  test "the room limit rejects a join" do
    Application.put_env(:audio_flow_sfu, :max_participants, 1)
    on_exit(fn -> Application.put_env(:audio_flow_sfu, :max_participants, 100) end)
    name = room()
    {:ok, _alice} = TestClient.start(name, "alice")
    assert {:error, :room_full} = TestClient.start(name, "bob")
  end

  test "a join with the same identity replaces the older participant" do
    name = room()
    {:ok, first} = TestClient.start(name, "alice")
    {:ok, _second} = TestClient.start(name, "alice")
    assert_receive {:client, ^first, {:closed, :duplicate_identity}}, 5000
    assert_receive {:client, ^first, {:participant_down, :normal}}, 5000
    assert [%{identity: "alice"}] = Room.participants(Room.whereis(name))
  end

  test "a join to a running room does not call the room supervisor" do
    name = room()
    {:ok, _alice} = TestClient.start(name, "alice")
    supervisor = Process.whereis(AudioFlowSFU.Rooms)
    :erlang.trace(supervisor, true, [:receive])

    info = %{sid: "PA_probe", identity: "probe", tracks: []}
    assert {:ok, _room, [_alice]} = Room.join(name, info, self())

    :erlang.trace(supervisor, false, [:receive])
    refute_received {:trace, ^supervisor, :receive, {:"$gen_call", _, {:start_child, _}}}
  end

  test "an empty room stops after the empty timeout" do
    Application.put_env(:audio_flow_sfu, :empty_timeout_ms, 50)
    on_exit(fn -> Application.put_env(:audio_flow_sfu, :empty_timeout_ms, 30_000) end)
    name = room()
    {:ok, alice} = TestClient.start(name, "alice")
    room = Room.whereis(name)
    ref = Process.monitor(room)
    :ok = WebRTC.leave(TestClient.participant(alice))
    assert_receive {:DOWN, ^ref, :process, ^room, :normal}, 1000
  end
end
