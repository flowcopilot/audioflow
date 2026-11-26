defmodule AudioFlowSFU.RoomTest do
  # Some tests change the room limits in the application environment.
  use ExUnit.Case, async: false
  alias AudioFlowSFU.Participant.WebRTC
  alias AudioFlowSFU.Room
  alias AudioFlowSFU.TestClient

  defp room, do: "room-#{System.unique_integer([:positive])}"

  defp connected(client) do
    assert_receive {:client, ^client, :client_connected}, 5000
  end

  defp payload(n), do: <<n::8, :binary.copy(<<0xAB>>, 59)::binary>>

  # Publishes until the subscriber receives one packet, then checks a run of
  # packets in order. The first packets can arrive before the subscriber's
  # transceiver is negotiated.
  defp assert_forwarded(publisher, subscriber) do
    Enum.reduce_while(1..200, nil, fn n, _ ->
      TestClient.send_audio(publisher, n, payload(n))

      receive do
        {:client, ^subscriber, {:rtp, _}} -> {:halt, :ok}
      after
        20 -> {:cont, nil}
      end
    end)

    flush_rtp(subscriber)

    for n <- 1000..1009, do: TestClient.send_audio(publisher, n, payload(rem(n, 256)))

    received =
      for _ <- 1..10 do
        assert_receive {:client, ^subscriber, {:rtp, packet}}, 2000
        packet.payload
      end

    assert received == for(n <- 1000..1009, do: payload(rem(n, 256)))
  end

  # Offers can follow each other; waits for one that matches.
  defp await_offer(client, match?) do
    assert_receive {:client, ^client, {:offer, mids}}, 5000
    if match?.(mids), do: mids, else: await_offer(client, match?)
  end

  defp flush_rtp(client) do
    receive do
      {:client, ^client, {:rtp, _}} -> flush_rtp(client)
    after
      50 -> :ok
    end
  end

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
