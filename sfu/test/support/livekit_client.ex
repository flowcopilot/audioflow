defmodule AudioFlowSFU.LiveKitClient do
  @moduledoc false
  # A LiveKit protocol v1 client for tests: one ExWebRTC peer that makes every
  # offer, as livekit-client does with a single peer connection.
  use GenServer
  alias AudioFlowSFU.LiveKit.Proto
  alias AudioFlowSFU.Token
  alias AudioFlowSFU.WebSocketClient, as: WS
  alias ExWebRTC.ICECandidate
  alias ExWebRTC.MediaStreamTrack
  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription

  @doc """
  Options: `:publish` (add a microphone track), `:sections` (receive-only
  audio sections in the first offer, 3), `:gzip`, `:reconnect` (participant
  SID), `:token_room`.
  """
  def start(port, room, identity, options \\ []),
    do: GenServer.start(__MODULE__, {port, room, identity, options, self()})

  def send_audio(client, payload), do: GenServer.call(client, {:send_audio, payload})
  def request(client, message), do: GenServer.call(client, {:request, message})
  def close_socket(client), do: GenServer.call(client, :close_socket)
  def pc(client), do: GenServer.call(client, :pc)

  @impl true
  def init({port, room, identity, options, test}) do
    {:ok, pc} = PeerConnection.start_link()
    sections = Keyword.get(options, :sections, 3)
    # livekit-client always has data channels, so its offer has a section.
    {:ok, _} = PeerConnection.create_data_channel(pc, "_reliable")

    for _ <- 1..sections//1,
        do: {:ok, _} = PeerConnection.add_transceiver(pc, :audio, direction: :recvonly)

    {track, add_tracks} =
      if Keyword.get(options, :publish, false) do
        track = MediaStreamTrack.new(:audio, ["stream"])
        {:ok, _} = PeerConnection.add_track(pc, track)

        request = %Proto.AddTrackRequest{
          cid: Integer.to_string(track.id),
          name: "microphone",
          type: :AUDIO,
          source: :MICROPHONE
        }

        {track, [request]}
      else
        {nil, []}
      end

    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)

    join = %Proto.JoinRequest{
      connection_settings: %Proto.ConnectionSettings{auto_subscribe: true},
      add_track_requests: add_tracks,
      publisher_offer: %Proto.SessionDescription{type: "offer", sdp: offer.sdp, id: 1},
      reconnect: Keyword.has_key?(options, :reconnect),
      participant_sid: Keyword.get(options, :reconnect, "")
    }

    token = Token.generate("key", "secret", identity, room)
    path = "/rtc/v1?access_token=#{token}&join_request=#{wrap(join, options)}"
    socket = WS.connect(port, path)
    :ok = :inet.setopts(socket, active: :once)

    {:ok,
     %{
       test: test,
       socket: socket,
       pc: pc,
       track: track,
       sequence: 1,
       offer_id: 1,
       buffer: <<>>
     }}
  end

  defp wrap(join, options) do
    bytes = Proto.JoinRequest.encode(join)

    wrapped =
      if Keyword.get(options, :gzip, false),
        do: %Proto.WrappedJoinRequest{compression: :GZIP, join_request: :zlib.gzip(bytes)},
        else: %Proto.WrappedJoinRequest{compression: :NONE, join_request: bytes}

    wrapped |> Proto.WrappedJoinRequest.encode() |> Base.url_encode64()
  end

  @impl true
  def handle_call(:pc, _, s), do: {:reply, s.pc, s}

  def handle_call({:send_audio, payload}, _, s) do
    packet =
      ExRTP.Packet.new(payload,
        sequence_number: rem(s.sequence, 65_536),
        timestamp: s.sequence * 960
      )

    {:reply, PeerConnection.send_rtp(s.pc, s.track.id, packet), %{s | sequence: s.sequence + 1}}
  end

  def handle_call({:request, message}, _, s), do: {:reply, send_request(s, message), s}

  def handle_call(:close_socket, _, s) do
    :gen_tcp.close(s.socket)
    {:reply, :ok, %{s | socket: nil}}
  end

  defp send_request(s, message) do
    WS.send_binary(s.socket, Proto.SignalRequest.encode(%Proto.SignalRequest{message: message}))
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = s) do
    s = frames(%{s | buffer: s.buffer <> data})
    :ok = :inet.setopts(socket, active: :once)
    {:noreply, s}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = s) do
    send(s.test, {:livekit, self(), :closed})
    {:noreply, %{s | socket: nil}}
  end

  def handle_info({:ex_webrtc, pc, {:ice_candidate, candidate}}, %{pc: pc} = s) do
    init = JSON.encode!(ICECandidate.to_json(candidate))

    if s.socket,
      do:
        send_request(
          s,
          {:trickle, %Proto.TrickleRequest{candidateInit: init, target: :PUBLISHER}}
        )

    {:noreply, s}
  end

  def handle_info({:ex_webrtc, pc, {:rtp, _, _, packet}}, %{pc: pc} = s) do
    send(s.test, {:livekit, self(), {:rtp, packet}})
    {:noreply, s}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, %{pc: pc} = s) do
    send(s.test, {:livekit, self(), :client_connected})
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  # Parses complete server frames (unmasked) from the TCP buffer.
  defp frames(%{buffer: <<_::4, opcode::4, 0::1, len::7, rest::binary>>} = s) do
    {length, rest} =
      case {len, rest} do
        {126, <<l::16, r::binary>>} -> {l, r}
        {127, <<l::64, r::binary>>} -> {l, r}
        {l, r} when l < 126 -> {l, r}
        _ -> {-1, rest}
      end

    case rest do
      <<payload::binary-size(^length), tail::binary>> ->
        frames(frame(opcode, payload, %{s | buffer: tail}))

      _ ->
        s
    end
  end

  defp frames(s), do: s

  defp frame(2, payload, s) do
    %Proto.SignalResponse{message: message} = Proto.SignalResponse.decode(payload)
    response(message, s)
  end

  defp frame(8, payload, s) do
    send(s.test, {:livekit, self(), {:close, payload}})
    s
  end

  defp frame(_, _, s), do: s

  defp response({:answer, answer}, s) do
    :ok =
      PeerConnection.set_remote_description(s.pc, %SessionDescription{
        type: :answer,
        sdp: answer.sdp
      })

    send(s.test, {:livekit, self(), {:answer, answer}})
    s
  end

  defp response({:trickle, %{candidateInit: init}}, s) do
    PeerConnection.add_ice_candidate(s.pc, ICECandidate.from_json(JSON.decode!(init)))
    s
  end

  # Adds the sections the server asks for and offers again.
  defp response({:media_sections_requirement, %{num_audios: audios} = requirement}, s) do
    for _ <- 1..audios//1,
        do: {:ok, _} = PeerConnection.add_transceiver(s.pc, :audio, direction: :recvonly)

    {:ok, offer} = PeerConnection.create_offer(s.pc)
    :ok = PeerConnection.set_local_description(s.pc, offer)
    id = s.offer_id + 1
    send_request(s, {:offer, %Proto.SessionDescription{type: "offer", sdp: offer.sdp, id: id}})
    send(s.test, {:livekit, self(), {:media_sections_requirement, requirement}})
    %{s | offer_id: id}
  end

  defp response(message, s) do
    send(s.test, {:livekit, self(), message})
    s
  end
end
