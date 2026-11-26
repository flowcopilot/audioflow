defmodule AudioFlowSFU.Signaling.LiveKit do
  @moduledoc """
  LiveKit client signal protocol v1 (one peer connection) over a WebSocket
  at `/rtc/v1?access_token=<jwt>&join_request=<WrappedJoinRequest>`.

  Messages are binary `SignalRequest` and `SignalResponse` protobufs. The
  client makes every offer; the server answers with `mid_to_track_id`. To
  subscribe the client to more tracks, the server sends
  `MediaSectionsRequirement` and the client offers again.

  Supported requests: `offer`, `answer`, `trickle`, `add_track`, `mute`,
  `leave`, `ping` and `ping_req`. Others are accepted and ignored.

  A reconnect (`JoinRequest.reconnect` with `participant_sid`) resumes the
  same participant and gets a `ReconnectResponse`. If the participant is
  gone, the server sends `LeaveRequest` with action `RECONNECT`, and the
  client joins again.
  """
  @behaviour WebSock
  require Logger
  alias AudioFlowSFU.LiveKit
  alias AudioFlowSFU.LiveKit.Proto
  alias AudioFlowSFU.Participant
  alias AudioFlowSFU.Participant.WebRTC

  @impl true
  def init(%{grants: grants, join: %Proto.JoinRequest{} = join} = options) do
    state = %{participant: nil, room: grants.room}

    case connect(grants, join, options) do
      {:ok, participant, response} ->
        Process.monitor(participant)
        state = %{state | participant: participant}
        frames = [frame(response) | publish(join, state)]
        {:push, frames, state}

      {:error, reason} when join.reconnect ->
        Logger.debug("LiveKit resume failed: #{inspect(reason)}")
        leave = %Proto.LeaveRequest{action: :RECONNECT, reason: :STATE_MISMATCH}
        {:stop, :normal, 1000, [frame({:leave, leave})], state}

      {:error, reason} ->
        leave = %Proto.LeaveRequest{action: :DISCONNECT, reason: :JOIN_FAILURE}
        {:stop, :normal, {1008, to_string(reason)}, [frame({:leave, leave})], state}
    end
  end

  defp connect(grants, %{reconnect: true, participant_sid: sid}, _options) when sid != "" do
    with {:ok, pid, join} <- WebRTC.resume_participant(sid, grants.identity, self()),
         do: {:ok, pid, {:reconnect, LiveKit.reconnect_response(join)}}
  end

  defp connect(grants, join, options) do
    settings = join.connection_settings || %Proto.ConnectionSettings{auto_subscribe: true}

    with {:ok, pid, info} <-
           WebRTC.start(grants,
             owner: self(),
             ice_servers: Map.get(options, :ice_servers, []),
             auto_subscribe: settings.auto_subscribe,
             negotiation: :client
           ),
         do: {:ok, pid, {:join, LiveKit.join_response(grants.room, info)}}
  end

  # Tracks and the first offer can come with the join request.
  defp publish(join, state) do
    published =
      Enum.flat_map(join.add_track_requests, fn request ->
        add_track(request, state)
      end)

    case join.publisher_offer do
      %Proto.SessionDescription{} = offer -> published ++ answer(offer, state)
      nil -> published
    end
  end

  @impl true
  def handle_in({data, opcode: :binary}, state) do
    %Proto.SignalRequest{message: message} = Proto.SignalRequest.decode(data)
    request(message, state)
  rescue
    _ -> {:ok, state}
  end

  def handle_in(_, state), do: {:ok, state}

  defp request({:offer, offer}, state), do: {:push, answer(offer, state), state}

  defp request({:answer, answer}, state) do
    WebRTC.answer(state.participant, LiveKit.json(answer))
    {:ok, state}
  end

  defp request({:trickle, %{candidateInit: init}}, state) do
    case JSON.decode(init) do
      {:ok, candidate} when is_map(candidate) -> WebRTC.candidate(state.participant, candidate)
      _ -> :ok
    end

    {:ok, state}
  end

  defp request({:add_track, request}, state), do: {:push, add_track(request, state), state}

  defp request({:mute, %{sid: sid, muted: muted}}, state) do
    WebRTC.mute(state.participant, sid, muted)
    {:ok, state}
  end

  defp request({:leave, _}, state) do
    WebRTC.leave(state.participant)
    {:stop, :normal, 1000, state}
  end

  defp request({:ping, timestamp}, state), do: {:push, frame({:pong, timestamp}), state}

  defp request({:ping_req, %{timestamp: timestamp}}, state) do
    pong = %Proto.Pong{
      last_ping_timestamp: timestamp,
      timestamp: System.system_time(:millisecond)
    }

    {:push, frame({:pong_resp, pong}), state}
  end

  defp request(_, state), do: {:ok, state}

  defp answer(offer, state) do
    case WebRTC.offer(state.participant, LiveKit.json(offer)) do
      {:ok, answer, mids} -> [frame({:answer, LiveKit.description(answer, offer.id, mids)})]
      {:error, reason} -> log([], :offer, reason)
    end
  end

  defp add_track(%Proto.AddTrackRequest{type: :AUDIO} = request, state) do
    case WebRTC.add_track(state.participant, request.cid, request.name, request.muted) do
      {:ok, track} ->
        response = %Proto.TrackPublishedResponse{cid: request.cid, track: LiveKit.track(track)}
        [frame({:track_published, response})]

      {:error, reason} ->
        log([], :add_track, reason)
    end
  end

  # Audio only.
  defp add_track(_request, _state), do: []

  defp log(result, what, reason) do
    Logger.debug("LiveKit #{what} failed: #{inspect(reason)}")
    result
  end

  @impl true
  def handle_info({Participant, pid, event}, %{participant: pid} = state), do: event(event, state)

  def handle_info({:DOWN, _, :process, pid, _}, %{participant: pid} = state),
    do: {:stop, :normal, 1000, state}

  def handle_info(_, state), do: {:ok, state}

  defp event({:candidate, candidate}, state) do
    trickle = %Proto.TrickleRequest{candidateInit: JSON.encode!(candidate), target: :PUBLISHER}
    {:push, frame({:trickle, trickle}), state}
  end

  defp event({event, info}, state) when event in [:participant_joined, :participant_updated],
    do: update(LiveKit.participant(info), state)

  defp event({:participant_left, info}, state), do: update(LiveKit.left(info), state)

  defp event({:media_sections, audios}, state) do
    requirement = %Proto.MediaSectionsRequirement{num_audios: audios, num_videos: 0}
    {:push, frame({:media_sections_requirement, requirement}), state}
  end

  defp event({:closed, reason}, state) do
    leave = %Proto.LeaveRequest{action: :DISCONNECT, reason: disconnect_reason(reason)}
    {:stop, :normal, 1000, [frame({:leave, leave})], state}
  end

  defp event(_, state), do: {:ok, state}

  defp update(participant, state) do
    update = %Proto.ParticipantUpdate{participants: [participant]}
    {:push, frame({:update, update}), state}
  end

  defp disconnect_reason(:duplicate_identity), do: :DUPLICATE_IDENTITY
  defp disconnect_reason(:resumed_elsewhere), do: :DUPLICATE_IDENTITY
  defp disconnect_reason(:away_timeout), do: :CONNECTION_TIMEOUT
  defp disconnect_reason(_), do: :UNKNOWN_REASON

  # A closed socket does not leave: the participant waits for a reconnect.
  @impl true
  def terminate(_reason, _state), do: :ok

  defp frame(message), do: {:binary, LiveKit.encode(message)}
end
