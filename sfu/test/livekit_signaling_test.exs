defmodule AudioFlowSFU.Signaling.LiveKitTest do
  use ExUnit.Case, async: false
  alias AudioFlowSFU.LiveKit
  alias AudioFlowSFU.LiveKit.Proto
  alias AudioFlowSFU.LiveKitClient, as: Client
  alias AudioFlowSFU.Token
  alias AudioFlowSFU.WebSocketClient, as: WS

  setup do
    Application.put_env(:audio_flow_sfu, :api_keys, %{"key" => "secret"})
    on_exit(fn -> Application.put_env(:audio_flow_sfu, :api_keys, %{}) end)
    server = start_supervised!({Bandit, plug: AudioFlowSFU.Router, port: 0, ip: :loopback})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{port: port, room: "livekit-#{System.unique_integer([:positive])}"}
  end

  defp payload(n), do: <<n::8, :binary.copy(<<0x5A>>, 59)::binary>>

  defp publisher(port, room) do
    {:ok, alice} = Client.start(port, room, "alice", publish: true, gzip: true)
    assert_receive {:livekit, ^alice, {:join, join}}, 5000
    assert %{identity: "alice", sid: "PA_" <> _} = join.participant
    assert join.server_info.protocol == 17
    assert join.ping_interval > 0 and join.ping_timeout > 0
    assert_receive {:livekit, ^alice, {:track_published, published}}, 5000
    assert %{track: %{sid: "TR_" <> _ = track, type: :AUDIO}} = published
    assert_receive {:livekit, ^alice, {:answer, %{id: 1}}}, 5000
    assert_receive {:livekit, ^alice, :client_connected}, 5000
    {alice, track}
  end

  # Sends until the subscriber gets audio; the first packets can arrive before
  # the subscriber's section is connected.
  defp assert_audio(publisher, subscriber) do
    Enum.reduce_while(1..250, nil, fn n, _ ->
      Client.send_audio(publisher, payload(n))

      receive do
        {:livekit, ^subscriber, {:rtp, %{payload: <<_, 0x5A, _::binary>>}}} -> {:halt, :ok}
      after
        20 -> {:cont, nil}
      end
    end)
    |> case do
      :ok -> :ok
      nil -> flunk("no audio reached the subscriber")
    end
  end

  test "a publisher's offer, track and audio reach a subscriber on a free section",
       %{port: port, room: room} do
    {alice, track} = publisher(port, room)

    {:ok, bob} = Client.start(port, room, "bob")
    assert_receive {:livekit, ^bob, {:join, join}}, 5000

    assert [%{identity: "alice", tracks: [%{sid: ^track}], state: :ACTIVE}] =
             join.other_participants

    assert_receive {:livekit, ^bob, {:answer, %{mid_to_track_id: mids}}}, 5000
    assert track in Map.values(mids)
    assert_receive {:livekit, ^bob, :client_connected}, 5000
    assert_audio(alice, bob)

    # Alice sees Bob join.
    assert_receive {:livekit, ^alice, {:update, %{participants: [%{identity: "bob"}]}}}, 5000
  end

  test "the server asks for a media section when the client has none",
       %{port: port, room: room} do
    {alice, track} = publisher(port, room)
    {:ok, bob} = Client.start(port, room, "bob", sections: 0)
    assert_receive {:livekit, ^bob, {:media_sections_requirement, %{num_audios: 1}}}, 5000
    assert_receive {:livekit, ^bob, {:answer, %{id: 2, mid_to_track_id: mids}}}, 5000
    assert track in Map.values(mids)
    assert_audio(alice, bob)
  end

  test "ping, leave and the participant update for a leaving member",
       %{port: port, room: room} do
    {alice, _track} = publisher(port, room)
    {:ok, bob} = Client.start(port, room, "bob")
    assert_receive {:livekit, ^bob, {:join, _}}, 5000

    Client.request(bob, {:ping_req, %Proto.Ping{timestamp: 1234}})
    assert_receive {:livekit, ^bob, {:pong_resp, %{last_ping_timestamp: 1234}}}, 5000

    Client.request(bob, {:leave, %Proto.LeaveRequest{}})

    assert_receive {:livekit, ^alice,
                    {:update, %{participants: [%{identity: "bob", state: :DISCONNECTED}]}}},
                   5000
  end

  test "a reconnect with the participant SID resumes the same participant",
       %{port: port, room: room} do
    {alice, _track} = publisher(port, room)
    {:ok, bob} = Client.start(port, room, "bob")
    assert_receive {:livekit, ^bob, {:join, %{participant: %{sid: sid}}}}, 5000
    :ok = Client.close_socket(bob)

    {:ok, again} = Client.start(port, room, "bob", reconnect: sid)
    assert_receive {:livekit, ^again, {:reconnect, %Proto.ReconnectResponse{}}}, 5000

    refute_receive {:livekit, ^alice,
                    {:update, %{participants: [%{identity: "bob", state: :DISCONNECTED}]}}},
                   300

    expired = Token.generate("key", "secret", "bob", room, ttl_s: -1)
    assert WS.refused(port, "/rtc/v1?access_token=#{expired}") =~ "401"

    {:ok, gone} = Client.start(port, room, "carol", reconnect: "PA_unknown")
    assert_receive {:livekit, ^gone, {:leave, %{action: :RECONNECT}}}, 5000
  end

  test "validate and the unsupported v0 path", %{port: port, room: room} do
    token = Token.generate("key", "secret", "dave", room)
    assert WS.refused(port, "/rtc/v1/validate?access_token=#{token}") =~ "200"
    assert WS.refused(port, "/rtc/v1/validate?access_token=bad") =~ "401"
    assert WS.refused(port, "/rtc?access_token=#{token}") =~ "404"
    assert WS.refused(port, "/rtc/v1?access_token=#{token}&join_request=%%") =~ "400"
  end

  test "join requests decode raw and gzip, and refuse oversized gzip" do
    request = %Proto.JoinRequest{participant_sid: "PA_x"}
    bytes = Proto.JoinRequest.encode(request)

    for wrapped <- [
          %Proto.WrappedJoinRequest{compression: :NONE, join_request: bytes},
          %Proto.WrappedJoinRequest{compression: :GZIP, join_request: :zlib.gzip(bytes)}
        ] do
      encoded = wrapped |> Proto.WrappedJoinRequest.encode() |> Base.url_encode64()
      assert {:ok, %{participant_sid: "PA_x"}} = LiveKit.decode_join_request(encoded)
    end

    bomb = :zlib.gzip(:binary.copy(<<0>>, 2_000_000))

    encoded =
      %Proto.WrappedJoinRequest{compression: :GZIP, join_request: bomb}
      |> Proto.WrappedJoinRequest.encode()
      |> Base.url_encode64()

    assert {:error, :invalid_join_request} = LiveKit.decode_join_request(encoded)
  end
end
