defmodule AudioFlowSFU.Signaling.JSONTest do
  use ExUnit.Case, async: false
  alias AudioFlowSFU.Token
  alias AudioFlowSFU.WebSocketClient, as: WS
  alias ExWebRTC.ICECandidate
  alias ExWebRTC.MediaStreamTrack
  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription

  setup do
    Application.put_env(:audio_flow_sfu, :api_keys, %{"key" => "secret"})
    on_exit(fn -> Application.put_env(:audio_flow_sfu, :api_keys, %{}) end)
    server = start_supervised!({Bandit, plug: AudioFlowSFU.Router, port: 0, ip: :loopback})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  # Each test uses its own room: an away participant stays in its room.
  defp path(identity) do
    room = "json-#{inspect(self())}"
    "/ws?access_token=" <> Token.generate("key", "secret", identity, room)
  end

  defp recv_type(socket, type) do
    case WS.recv(socket, 5000) do
      {:json, %{"type" => ^type} = message} -> message
      {:json, _other} -> recv_type(socket, type)
    end
  end

  test "a bad token is refused before the upgrade", %{port: port} do
    assert WS.refused(port, "/ws?access_token=bad") =~ "401"
    assert WS.refused(port, "/ws") =~ "401"
  end

  test "a client joins, answers the server offer, trickles ICE and connects", %{port: port} do
    socket = WS.connect(port, path("alice"))
    join = recv_type(socket, "join")

    assert %{"identity" => "alice", "sid" => "PA_" <> _, "kind" => "standard"} =
             join["participant"]

    assert join["others"] == []

    offer = recv_type(socket, "offer")
    assert offer["tracks"] == %{}
    {:ok, pc} = PeerConnection.start_link()
    :ok = PeerConnection.set_remote_description(pc, SessionDescription.from_json(offer))
    {:ok, _} = PeerConnection.add_track(pc, MediaStreamTrack.new(:audio))
    {:ok, answer} = PeerConnection.create_answer(pc)
    :ok = PeerConnection.set_local_description(pc, answer)
    WS.send_json(socket, SessionDescription.to_json(answer))

    connected = pump(socket, pc)
    assert connected["type"] == "connected"

    WS.send_json(socket, %{type: "ping"})
    assert recv_type(socket, "pong")
    WS.send_json(socket, %{type: "nope"})
    assert %{"reason" => "invalid_message"} = recv_type(socket, "error")

    WS.send_json(socket, %{type: "leave"})
    assert {:close, <<1000::16, _::binary>>} = recv_until_close(socket)
  end

  test "a dropped socket resumes the same participant with the resume token", %{port: port} do
    socket = WS.connect(port, path("carol"))
    %{"participant" => %{"sid" => sid}, "resume_token" => token} = recv_type(socket, "join")
    offer = recv_type(socket, "offer")
    :gen_tcp.close(socket)

    socket = WS.connect(port, path("carol") <> "&resume=" <> token)

    assert %{"resumed" => true, "participant" => %{"sid" => ^sid}, "resume_token" => ^token} =
             recv_type(socket, "join")

    # The answer was never sent, so the server sends the same offer again.
    assert recv_type(socket, "offer")["sdp"] == offer["sdp"]

    other = WS.connect(port, path("mallory"))
    _ = recv_type(other, "join")
    refused = WS.connect(port, path("mallory") <> "&resume=" <> token)
    assert {:close, <<1008::16, "identity_mismatch">>} = recv_until_close(refused)
  end

  # Moves ICE candidates both ways until the server reports `connected`.
  defp pump(socket, pc) do
    receive do
      {:ex_webrtc, ^pc, {:ice_candidate, candidate}} ->
        WS.send_json(socket, %{type: "candidate", candidate: ICECandidate.to_json(candidate)})
        pump(socket, pc)
    after
      0 ->
        case WS.recv(socket, 50) do
          {:json, %{"type" => "candidate", "candidate" => c}} ->
            PeerConnection.add_ice_candidate(pc, ICECandidate.from_json(c))
            pump(socket, pc)

          {:json, %{"type" => "connected"} = message} ->
            message

          {:json, _} ->
            pump(socket, pc)

          {:error, :timeout} ->
            pump(socket, pc)
        end
    end
  end

  defp recv_until_close(socket) do
    case WS.recv(socket, 5000) do
      {:close, _} = close -> close
      _ -> recv_until_close(socket)
    end
  end
end
