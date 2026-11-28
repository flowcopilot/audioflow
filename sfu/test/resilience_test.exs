defmodule AudioFlowSFU.ResilienceTest do
  use ExUnit.Case, async: false
  import AudioFlowSFU.MediaAssertions
  alias AudioFlowSFU.Participant.WebRTC
  alias AudioFlowSFU.Room
  alias AudioFlowSFU.TestClient

  defp room, do: "resilience-#{System.unique_integer([:positive])}"

  defp pair(name) do
    {:ok, alice} = TestClient.start(name, "alice")
    connected(alice)
    assert_receive {:client, ^alice, {:track_published, _}}, 5000
    {:ok, bob} = TestClient.start(name, "bob", can_publish: false)
    connected(bob)
    assert_forwarded(alice, bob)
    {alice, bob}
  end

  defp await(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && await(fun, attempts - 1)
    end
  end

  test "media continues on the same peer connections after the room process crashes" do
    name = room()
    {alice, bob} = pair(name)
    old = Room.whereis(name)
    pcs = for c <- [alice, bob], do: :sys.get_state(TestClient.participant(c)).pc

    Process.exit(old, :kill)

    await(fn ->
      (pid = Room.whereis(name)) && pid != old && length(Room.participants(pid)) == 2
    end)

    assert pcs == for(c <- [alice, bob], do: :sys.get_state(TestClient.participant(c)).pc)
    assert_forwarded(alice, bob)
    refute_received {:client, ^bob, {:participant_left, _}}
  end

  test "a room crash during a renegotiation does not stop the new track" do
    name = room()
    {:ok, bob} = TestClient.start(name, "bob", can_publish: false)
    connected(bob)
    {:ok, alice} = TestClient.start(name, "alice")
    connected(alice)
    assert_receive {:client, ^alice, {:track_published, %{sid: track}}}, 5000

    # Bob's offer for Alice's track is on its way; the room crashes now.
    Process.exit(Room.whereis(name), :kill)
    await_offer(bob, &(track in Map.values(&1)))
    assert_forwarded(alice, bob)
  end

  test "a member that stops while the room is down is removed by the sync" do
    name = room()
    {alice, bob} = pair(name)
    alice_participant = TestClient.participant(alice)

    Process.exit(Room.whereis(name), :kill)
    Process.exit(alice_participant, :kill)

    assert_receive {:client, ^bob, {:participant_left, %{identity: "alice"}}}, 5000
    await_offer(bob, &(&1 == %{}))
    assert [%{identity: "bob"}] = Room.participants(Room.whereis(name))
  end

  test "a dropped signal keeps media, and a resume gets the offer it missed" do
    name = room()
    test = self()

    :telemetry.attach_many(
      "resilience-#{name}",
      [[:audio_flow_sfu, :participant, :away], [:audio_flow_sfu, :participant, :resume]],
      fn event, _, %{room: ^name, identity: identity}, _ ->
        send(test, {:telemetry, List.last(event), identity})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("resilience-#{name}") end)

    {:ok, bob} = TestClient.start(name, "bob", can_publish: false)
    connected(bob)
    %{participant: %{sid: sid}} = TestClient.join_info(bob)
    flush_offers(bob)
    :ok = TestClient.drop_signal(bob)
    assert_receive {:telemetry, :away, "bob"}, 1000

    # Alice publishes while Bob has no signaling: Bob's offer waits.
    {:ok, alice} = TestClient.start(name, "alice")
    connected(alice)
    assert_receive {:client, ^alice, {:track_published, %{sid: track}}}, 5000
    refute_receive {:client, ^bob, {:offer, _}}, 300

    assert {:ok, %{participant: %{sid: ^sid}, others: [%{identity: "alice"}]}} =
             TestClient.resume(bob)

    assert_receive {:telemetry, :resume, "bob"}, 1000
    await_offer(bob, &(track in Map.values(&1)))
    assert_forwarded(alice, bob)
  end

  test "a session that is not resumed within the away timeout ends" do
    name = room()

    {:ok, bob} =
      TestClient.start(name, "bob", can_publish: false, options: [away_timeout_ms: 100])

    connected(bob)
    participant = TestClient.participant(bob)
    ref = Process.monitor(participant)
    :ok = TestClient.drop_signal(bob)
    assert_receive {:DOWN, ^ref, :process, ^participant, :normal}, 1000
    assert {:error, :unknown_session} = TestClient.resume(bob)
  end

  test "a participant that never connects closes after the connect timeout" do
    {:ok, participant, _} =
      WebRTC.start(TestClient.grants(room(), "idle"), owner: self(), connect_timeout_ms: 100)

    ref = Process.monitor(participant)
    assert_receive {AudioFlowSFU.Participant, ^participant, {:closed, :connect_timeout}}, 2000
    assert_receive {:DOWN, ^ref, :process, ^participant, :normal}, 1000
  end

  test "an offer without an answer is sent again, then the participant closes" do
    {:ok, participant, _} =
      WebRTC.start(TestClient.grants(room(), "silent"), owner: self(), answer_timeout_ms: 100)

    ref = Process.monitor(participant)
    assert_receive {AudioFlowSFU.Participant, ^participant, {:offer, sdp, mids}}, 2000
    assert_receive {AudioFlowSFU.Participant, ^participant, {:offer, ^sdp, ^mids}}, 2000
    assert_receive {AudioFlowSFU.Participant, ^participant, {:offer, ^sdp, ^mids}}, 2000
    assert_receive {AudioFlowSFU.Participant, ^participant, {:closed, :answer_timeout}}, 2000
    assert_receive {:DOWN, ^ref, :process, ^participant, :normal}, 1000
  end

  test "a client-negotiated participant that resumes asks for the sections it missed" do
    name = room()
    away = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, bob, %{resume_token: token}} =
      WebRTC.start(TestClient.grants(name, "bob", %{can_publish: false}),
        owner: away,
        negotiation: :client
      )

    Process.exit(away, :kill)
    await(fn -> :sys.get_state(bob).owner == nil end)

    {:ok, alice} = TestClient.start(name, "alice")
    connected(alice)
    assert_receive {:client, ^alice, {:track_published, _}}, 5000
    await(fn -> Enum.any?(:sys.get_state(bob).subscriptions) end)
    refute_received {AudioFlowSFU.Participant, ^bob, {:media_sections, _}}

    assert {:ok, ^bob, _} = WebRTC.resume(token, "bob", self())
    assert_receive {AudioFlowSFU.Participant, ^bob, {:media_sections, 1}}, 1000
  end

  test "a resume with another identity is refused" do
    {:ok, bob} = TestClient.start(room(), "bob", can_publish: false)
    %{resume_token: token} = TestClient.join_info(bob)
    assert {:error, :identity_mismatch} = WebRTC.resume(token, "mallory", self())
    assert {:error, :unknown_session} = WebRTC.resume("unknown", "bob", self())
  end

  test "an ICE restart sends new credentials and media continues" do
    name = room()
    {alice, bob} = pair(name)
    assert_receive {:client, ^bob, {:offer_sdp, first}}, 1000
    flush_offers(bob)

    :ok = WebRTC.restart_ice(TestClient.participant(bob))
    assert_receive {:client, ^bob, {:offer_sdp, restarted}}, 5000
    refute ufrag(restarted) == ufrag(first)
    assert_forwarded(alice, bob)
  end

  defp ufrag(sdp), do: Regex.run(~r/a=ice-ufrag:(\S+)/, sdp, capture: :all_but_first)

  defp flush_offers(client) do
    receive do
      {:client, ^client, {:offer_sdp, _}} -> flush_offers(client)
      {:client, ^client, {:offer, _}} -> flush_offers(client)
    after
      100 -> :ok
    end
  end
end
