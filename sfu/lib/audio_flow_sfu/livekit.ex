defmodule AudioFlowSFU.LiveKit do
  @moduledoc """
  Conversions between the SFU participant model and the LiveKit protocol
  messages (`AudioFlowSFU.LiveKit.Proto`, generated from livekit/protocol
  v1.54.2 by `scripts/gen_livekit_proto.sh`).

  The server reports protocol 17: from protocol 18 LiveKit clients expect
  negotiated data channels, which `ex_webrtc` does not support yet.
  """
  alias AudioFlowSFU.LiveKit.Proto

  @protocol 17
  @version Mix.Project.config()[:version]
  @ping_interval_s 5
  @ping_timeout_s 15

  def protocol, do: @protocol

  @doc "Decodes the `join_request` query parameter (base64url `WrappedJoinRequest`)."
  def decode_join_request(nil), do: {:ok, %Proto.JoinRequest{}}

  def decode_join_request(encoded) when is_binary(encoded) and byte_size(encoded) <= 262_144 do
    with {:ok, wrapped} <- Base.url_decode64(String.trim_trailing(encoded, "="), padding: false),
         %Proto.WrappedJoinRequest{} = request <- Proto.WrappedJoinRequest.decode(wrapped),
         {:ok, bytes} <- uncompress(request) do
      {:ok, Proto.JoinRequest.decode(bytes)}
    else
      _ -> {:error, :invalid_join_request}
    end
  rescue
    _ -> {:error, :invalid_join_request}
  end

  def decode_join_request(_), do: {:error, :invalid_join_request}

  # A bounded inflate: a small request must not expand without limit.
  defp uncompress(%{compression: :NONE, join_request: bytes}), do: {:ok, bytes}

  defp uncompress(%{compression: :GZIP, join_request: bytes}) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      inflate(z, :zlib.safeInflate(z, bytes), [], 0)
    after
      :zlib.close(z)
    end
  end

  defp uncompress(_), do: {:error, :invalid_join_request}

  defp inflate(_z, _, _acc, size) when size > 1_048_576, do: {:error, :invalid_join_request}

  defp inflate(z, {:continue, data}, acc, size),
    do: inflate(z, :zlib.safeInflate(z, []), [acc | data], size + IO.iodata_length(data))

  defp inflate(_z, {:finished, data}, acc, _size), do: {:ok, IO.iodata_to_binary([acc | data])}

  def join_response(room, join) do
    %Proto.JoinResponse{
      room: room(room, length(join.others) + 1),
      participant: participant(join.participant),
      other_participants: Enum.map(join.others, &participant/1),
      server_version: @version,
      server_info: server_info(),
      ice_servers: Enum.map(join.ice_servers, &ice_server/1),
      subscriber_primary: false,
      ping_interval: @ping_interval_s,
      ping_timeout: @ping_timeout_s
    }
  end

  def reconnect_response(join) do
    %Proto.ReconnectResponse{
      ice_servers: Enum.map(join.ice_servers, &ice_server/1),
      server_info: server_info()
    }
  end

  defp server_info,
    do: %Proto.ServerInfo{edition: :Standard, version: @version, protocol: @protocol}

  def room(name, participants \\ 0) do
    %Proto.Room{
      sid: "RM_" <> Base.encode32(:crypto.hash(:sha256, name), case: :lower, padding: false),
      name: name,
      num_participants: participants
    }
    |> Map.update!(:sid, &binary_part(&1, 0, 15))
  end

  def participant(info, state \\ :ACTIVE) do
    %Proto.ParticipantInfo{
      sid: info.sid,
      identity: info.identity,
      name: info.name,
      metadata: info.metadata,
      state: state,
      kind: kind(info.kind),
      joined_at: info.joined_at,
      joined_at_ms: info.joined_at * 1000,
      version: info.version,
      is_publisher: info.tracks != [],
      tracks: Enum.map(info.tracks, &track/1),
      permission: struct(Proto.ParticipantPermission, info.permission)
    }
  end

  def left(info), do: participant(%{info | version: info.version + 1}, :DISCONNECTED)

  def track(track) do
    %Proto.TrackInfo{
      sid: track.sid,
      type: :AUDIO,
      name: track.name,
      muted: track.muted,
      source: :MICROPHONE,
      mime_type: track.mime_type
    }
  end

  defp kind(:agent), do: :AGENT
  defp kind(:sip), do: :SIP
  defp kind(_), do: :STANDARD

  defp ice_server(%{urls: urls} = server) do
    %Proto.ICEServer{
      urls: List.wrap(urls),
      username: Map.get(server, :username, ""),
      credential: Map.get(server, :credential, "")
    }
  end

  def description(%{"type" => type, "sdp" => sdp}, id, mids \\ %{}),
    do: %Proto.SessionDescription{type: type, sdp: sdp, id: id, mid_to_track_id: mids}

  def json(%Proto.SessionDescription{type: type, sdp: sdp}), do: %{"type" => type, "sdp" => sdp}

  def encode(message), do: Proto.SignalResponse.encode(%Proto.SignalResponse{message: message})
end
