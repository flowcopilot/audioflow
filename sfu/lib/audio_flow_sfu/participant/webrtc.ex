defmodule AudioFlowSFU.Participant.WebRTC do
  @moduledoc """
  One client with one `ExWebRTC.PeerConnection` for publish and subscribe.

  The server makes the first offer. It has one receive-only audio transceiver
  when the client may publish, and one send-only transceiver for each
  subscribed track. Later changes renegotiate with a new server offer. A
  client offer is accepted only while no server offer waits for an answer;
  otherwise it gets `{:error, :glare}` and the client must roll back.

  Events for the owner (`{AudioFlowSFU.Participant, pid, event}`):
  `{:offer, sdp_json, mids}` (`mids` maps each SDP mid to a track SID),
  `{:candidate, json}`, `:connected`, `{:track_published, track}`,
  `{:participant_joined, info}`, `{:participant_updated, info}`,
  `{:participant_left, info}`, and `{:closed, reason}` before it stops.

  The participant outlives its owner. When the owner stops (for example, the
  signaling socket drops) or the connection fails, the participant waits for
  `:away_timeout_ms` (30 000). Media keeps flowing while the peer connection
  is up. `resume/3` with the resume token from the join gives the
  participant to a new owner and sends the pending offer again. A failed
  connection gets an ICE restart offer. If the room process crashes, the
  participant joins the restarted room again with the same SID.
  """
  use GenServer, restart: :temporary

  alias AudioFlowSFU.Participant
  alias AudioFlowSFU.Room
  alias AudioFlowSFU.Telemetry
  alias ExWebRTC.ICECandidate
  alias ExWebRTC.MediaStreamTrack
  alias ExWebRTC.PeerConnection
  alias ExWebRTC.RTPCodecParameters
  alias ExWebRTC.SessionDescription

  @vsn 1

  @opus %RTPCodecParameters{
    payload_type: 111,
    mime_type: "audio/opus",
    clock_rate: 48_000,
    channels: 2,
    sdp_fmtp_line: %ExSDP.Attribute.FMTP{pt: 111, minptime: 10, useinbandfec: true}
  }
  @pcmu %RTPCodecParameters{payload_type: 0, mime_type: "audio/PCMU", clock_rate: 8000}

  @doc """
  Starts and joins a participant for verified `grants`. Options: `:owner`
  (required), `:ice_servers`, `:auto_subscribe` (true), `:away_timeout_ms`.
  Returns the participant PID and
  `%{participant: info, others: [info], ice_servers: list, resume_token: binary}`.
  """
  def start(grants, options) do
    spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [{grants, options}]},
      restart: :temporary
    }

    with {:ok, pid} <- DynamicSupervisor.start_child(AudioFlowSFU.Participants, spec) do
      {:ok, pid, GenServer.call(pid, :join_info)}
    end
  end

  def start_link(argument), do: GenServer.start_link(__MODULE__, argument)

  @doc """
  Gives a running participant to a new owner. The identity must match the
  token of the new connection. Returns the same result as `start/2`.
  """
  def resume(resume_token, identity, owner) do
    case Registry.lookup(AudioFlowSFU.Registry, {:resume, resume_token}) do
      [{pid, _}] ->
        case GenServer.call(pid, {:resume, identity, owner}) do
          {:ok, join} -> {:ok, pid, join}
          error -> error
        end

      [] ->
        {:error, :unknown_session}
    end
  catch
    :exit, _ -> {:error, :unknown_session}
  end

  @doc "Sends an offer with new ICE credentials."
  def restart_ice(pid), do: GenServer.call(pid, :restart_ice)

  @doc "Applies a client offer. Returns the answer."
  def offer(pid, json), do: GenServer.call(pid, {:offer, json})
  @doc "Applies the client answer to the last server offer."
  def answer(pid, json), do: GenServer.call(pid, {:answer, json})
  def candidate(pid, json), do: GenServer.call(pid, {:candidate, json})
  def mute(pid, track_sid, muted?), do: GenServer.call(pid, {:mute, track_sid, muted?})
  def leave(pid), do: GenServer.call(pid, :leave)

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  @impl true
  def init({grants, options}) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(options, :owner)
    ice_servers = Keyword.get(options, :ice_servers, [])

    {:ok, pc} =
      PeerConnection.start_link(
        ice_servers: ice_servers,
        audio_codecs: [@opus, @pcmu],
        video_codecs: []
      )

    info = Participant.info(grants)
    resume_token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    {:ok, _} = Registry.register(AudioFlowSFU.Registry, {:resume, resume_token}, nil)

    case Room.join(grants.room, info, self()) do
      {:ok, room, others} ->
        Telemetry.participant(:join, info, grants.room)

        state = %{
          grants: grants,
          info: info,
          owner: owner,
          owner_ref: Process.monitor(owner),
          resume_token: resume_token,
          away_timeout:
            Keyword.get_lazy(options, :away_timeout_ms, fn ->
              Application.fetch_env!(:audio_flow_sfu, :away_timeout_ms)
            end),
          away_timer: nil,
          connection: :new,
          room: room,
          room_ref: Process.monitor(room),
          ice_servers: ice_servers,
          auto_subscribe: Keyword.get(options, :auto_subscribe, true),
          pc: pc,
          # Received client tracks: PeerConnection track id => track SID.
          published: %{},
          # Track SID => %{subscriber pid => monitor ref}.
          subscribers: %{},
          # Track SID => %{publisher, publisher_sid, track, sender, mime_type, ready}.
          subscriptions: %{},
          negotiating: false,
          renegotiate: false,
          ice_restart: false,
          # The last server offer, sent again to a resumed owner.
          pending_offer: nil,
          # Other members: participant SID => {info, pid}.
          members: Map.new(others, fn {info, pid} -> {info.sid, {info, pid}} end)
        }

        if grants.can_publish,
          do: {:ok, _} = PeerConnection.add_transceiver(pc, :audio, direction: :recvonly)

        # The data channel keeps one media section in every offer, so a client
        # with nothing to send or receive yet still connects.
        {:ok, _} = PeerConnection.create_data_channel(pc, "_reliable")

        {:ok, state, {:continue, :subscribe}}

      {:error, reason} ->
        PeerConnection.stop(pc)
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:subscribe, state) do
    state =
      Enum.reduce(state.members, state, fn {_, {info, pid}}, s -> sync_publisher(s, info, pid) end)

    {:noreply, negotiate(state)}
  end

  def handle_continue(:next, %{renegotiate: true} = state), do: {:noreply, negotiate(state)}
  def handle_continue(:next, state), do: {:noreply, state}

  @impl true
  def handle_call(:join_info, _from, state), do: {:reply, join_info(state), state}

  def handle_call({:resume, identity, owner}, _from, %{grants: %{identity: identity}} = state) do
    if state.owner_ref, do: Process.demonitor(state.owner_ref, [:flush])
    # A second connection with the same session replaces the first one.
    if state.owner, do: Participant.notify(state.owner, {:closed, :resumed_elsewhere})
    state = %{state | owner: owner, owner_ref: Process.monitor(owner)}
    Telemetry.participant(:resume, state.info, state.grants.room)

    with {description, mids} <- state.pending_offer,
         do: Participant.notify(owner, {:offer, description, mids})

    {:reply, {:ok, join_info(state)}, health(state)}
  end

  def handle_call({:resume, _, _}, _from, state),
    do: {:reply, {:error, :identity_mismatch}, state}

  def handle_call(:restart_ice, _from, state),
    do: {:reply, :ok, negotiate(%{state | ice_restart: true})}

  def handle_call({:offer, json}, _from, %{negotiating: true} = state) when is_map(json),
    do: {:reply, {:error, :glare}, state}

  def handle_call({:offer, json}, _from, state) do
    with {:ok, offer} <- description(json, "offer"),
         :ok <- PeerConnection.set_remote_description(state.pc, offer),
         {:ok, answer} <- PeerConnection.create_answer(state.pc),
         :ok <- PeerConnection.set_local_description(state.pc, answer) do
      state = ready_subscriptions(state)
      {:reply, {:ok, SessionDescription.to_json(answer), mids(state)}, state, {:continue, :next}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:answer, json}, _from, %{negotiating: true} = state) do
    with {:ok, answer} <- description(json, "answer"),
         :ok <- PeerConnection.set_remote_description(state.pc, answer) do
      state = ready_subscriptions(%{state | negotiating: false, pending_offer: nil})
      {:reply, :ok, state, {:continue, :next}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:answer, _}, _from, state), do: {:reply, {:error, :no_offer}, state}

  def handle_call({:candidate, %{"candidate" => line} = json}, _from, state)
      when is_binary(line) and byte_size(line) <= 4096 do
    {:reply, PeerConnection.add_ice_candidate(state.pc, ICECandidate.from_json(json)), state}
  rescue
    _ -> {:reply, {:error, :invalid_candidate}, state}
  end

  def handle_call({:candidate, _}, _from, state), do: {:reply, :ok, state}

  def handle_call({:mute, sid, muted?}, _from, state) when is_boolean(muted?) do
    if Enum.any?(state.info.tracks, &(&1.sid == sid)) do
      tracks =
        Enum.map(state.info.tracks, &if(&1.sid == sid, do: %{&1 | muted: muted?}, else: &1))

      {:reply, :ok, update_info(state, %{state.info | tracks: tracks})}
    else
      {:reply, {:error, :unknown_track}, state}
    end
  end

  def handle_call(:leave, _from, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_info({:ex_webrtc, pc, {:rtp, id, _rid, packet}}, %{pc: pc} = state) do
    with {:ok, sid} <- Map.fetch(state.published, id),
         {:ok, subscribers} <- Map.fetch(state.subscribers, sid) do
      Participant.forward(Map.keys(subscribers), sid, packet)
      |> Telemetry.dropped(sid, state.info, state.grants.room)
    end

    {:noreply, state}
  end

  def handle_info({Participant, :rtp, sid, packet}, state) do
    case state.subscriptions do
      %{^sid => %{ready: true, track: track}} ->
        PeerConnection.send_rtp(state.pc, track.id, packet)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(
        {:ex_webrtc, pc, {:track, %MediaStreamTrack{kind: :audio} = track}},
        %{pc: pc} = s
      ),
      do: {:noreply, publish(s, track)}

  def handle_info({:ex_webrtc, pc, {:ice_candidate, candidate}}, %{pc: pc} = state) do
    Participant.notify(state.owner, {:candidate, ICECandidate.to_json(candidate)})
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, %{pc: pc} = state) do
    Participant.notify(state.owner, :connected)
    {:noreply, health(%{state | connection: :connected})}
  end

  # A failed connection can come back with an ICE restart while the
  # participant waits.
  def handle_info({:ex_webrtc, pc, {:connection_state_change, :failed}}, %{pc: pc} = state) do
    state = %{state | connection: :failed}
    state = if state.owner, do: negotiate(%{state | ice_restart: true}), else: state
    {:noreply, health(state)}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :closed}}, %{pc: pc} = state),
    do: close(state, {:connection, :closed})

  def handle_info({:ex_webrtc, _, _}, state), do: {:noreply, state}

  def handle_info({Participant, :subscribe, sid, pid}, state) do
    if Enum.any?(state.info.tracks, &(&1.sid == sid)) do
      subscribers = Map.get(state.subscribers, sid, %{})

      subscribers =
        if Map.has_key?(subscribers, pid),
          do: subscribers,
          else: Map.put(subscribers, pid, Process.monitor(pid))

      {:noreply, %{state | subscribers: Map.put(state.subscribers, sid, subscribers)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({Participant, :unsubscribe, sid, pid}, state),
    do: {:noreply, drop_subscriber(state, sid, pid)}

  def handle_info({Room, _, {event, info, pid}}, state)
      when event in [:participant_joined, :participant_updated] do
    Participant.notify(state.owner, {event, info})
    state = %{state | members: Map.put(state.members, info.sid, {info, pid})}
    {:noreply, negotiate(sync_publisher(state, info, pid))}
  end

  def handle_info({Room, _, {:participant_left, info}}, state) do
    Participant.notify(state.owner, {:participant_left, info})
    state = %{state | members: Map.delete(state.members, info.sid)}
    {:noreply, negotiate(drop_publisher(state, info.sid))}
  end

  def handle_info({Room, _, {:sync, members}}, state),
    do: {:noreply, sync_members(state, members)}

  def handle_info({Room, _, :duplicate_identity}, state), do: close(state, :duplicate_identity)

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state) do
    Telemetry.participant(:away, state.info, state.grants.room)
    {:noreply, health(%{state | owner: nil, owner_ref: nil})}
  end

  # The room restarted. Join it again with the same SID; the room sends a
  # member list afterwards to settle changes made while it was down.
  def handle_info({:DOWN, ref, :process, _, _}, %{room_ref: ref} = state) do
    case Room.rejoin(state.grants.room, state.info, self()) do
      {:ok, room} -> {:noreply, %{state | room: room, room_ref: Process.monitor(room)}}
      {:error, reason} -> close(state, {:room_down, reason})
    end
  end

  def handle_info({:away_timeout, token}, %{away_timer: {_, token}} = state),
    do: close(%{state | away_timer: nil}, :away_timeout)

  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    state =
      Enum.reduce(Map.keys(state.subscribers), state, fn sid, s ->
        drop_subscriber(s, sid, pid)
      end)

    {:noreply, state}
  end

  def handle_info({:EXIT, pc, reason}, %{pc: pc} = state), do: close(state, {:peer, reason})
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for track <- state.info.tracks,
        do: Telemetry.track(:unpublish, track, state.info, state.grants.room)

    Telemetry.participant(:leave, state.info, state.grants.room)
    if Process.alive?(state.pc), do: PeerConnection.stop(state.pc)
    :ok
  end

  defp join_info(state) do
    %{
      participant: state.info,
      others: for({_, {info, _}} <- state.members, do: info),
      ice_servers: state.ice_servers,
      resume_token: state.resume_token
    }
  end

  # Waits while the owner is away or the connection has failed; cancels the
  # wait once both are back.
  defp health(state) do
    healthy? = state.owner != nil and state.connection != :failed

    case {healthy?, state.away_timer} do
      {true, nil} ->
        state

      {true, {timer, _}} ->
        Process.cancel_timer(timer)
        %{state | away_timer: nil}

      {false, nil} ->
        token = make_ref()
        timer = Process.send_after(self(), {:away_timeout, token}, state.away_timeout)
        %{state | away_timer: {timer, token}}

      {false, _} ->
        state
    end
  end

  ## Negotiation

  # The client answered or offered: send the next server offer if a change
  # waited for the exchange to finish.
  defp negotiate(%{negotiating: true} = state), do: %{state | renegotiate: true}

  defp negotiate(state) do
    with :stable <- PeerConnection.get_signaling_state(state.pc),
         {:ok, offer} <- PeerConnection.create_offer(state.pc, ice_restart: state.ice_restart),
         :ok <- PeerConnection.set_local_description(state.pc, offer) do
      {description, mids} = offer = {SessionDescription.to_json(offer), mids(state)}
      Participant.notify(state.owner, {:offer, description, mids})
      %{state | negotiating: true, renegotiate: false, ice_restart: false, pending_offer: offer}
    else
      _ -> %{state | renegotiate: true}
    end
  end

  defp description(%{"type" => type, "sdp" => sdp} = json, type)
       when is_binary(sdp) and byte_size(sdp) <= 65_536,
       do: {:ok, SessionDescription.from_json(json)}

  defp description(_, _), do: {:error, :invalid_description}

  defp mids(state) do
    by_track = Map.new(state.subscriptions, fn {sid, sub} -> {sub.track.id, sid} end)

    for tr <- PeerConnection.get_transceivers(state.pc),
        tr.mid != nil,
        sid = tr.sender.track && Map.get(by_track, tr.sender.track.id),
        sid != nil,
        into: %{},
        do: {tr.mid, sid}
  end

  ## Publishing

  defp publish(%{grants: %{can_publish: false}} = state, _track), do: state

  defp publish(state, track) do
    mime = receive_mime(state.pc, track.id)
    published = Participant.track(mime)
    Participant.notify(state.owner, {:track_published, published})
    Telemetry.track(:publish, published, state.info, state.grants.room)

    state = %{state | published: Map.put(state.published, track.id, published.sid)}
    update_info(state, %{state.info | tracks: state.info.tracks ++ [published]})
  end

  defp receive_mime(pc, track_id) do
    PeerConnection.get_transceivers(pc)
    |> Enum.find_value(@opus.mime_type, fn tr ->
      if tr.receiver.track.id == track_id, do: List.first(tr.codecs, @opus).mime_type
    end)
  end

  defp update_info(state, info) do
    Room.update(state.room, info)
    %{state | info: info}
  end

  defp drop_subscriber(state, sid, pid) do
    case state.subscribers do
      %{^sid => %{^pid => ref} = subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: Map.put(state.subscribers, sid, Map.delete(subscribers, pid))}

      _ ->
        state
    end
  end

  ## Subscribing

  # Matches the subscriptions for one publisher to its current tracks.
  defp sync_publisher(%{auto_subscribe: false} = state, _info, _pid), do: state
  defp sync_publisher(%{grants: %{can_subscribe: false}} = state, _info, _pid), do: state

  defp sync_publisher(state, info, pid) do
    current = MapSet.new(info.tracks, & &1.sid)

    state =
      Enum.reduce(state.subscriptions, state, fn
        {sid, %{publisher: ^pid}}, s -> if sid in current, do: s, else: unsubscribe(s, sid)
        _, s -> s
      end)

    Enum.reduce(info.tracks, state, fn track, s ->
      if Map.has_key?(s.subscriptions, track.sid), do: s, else: subscribe(s, info, track, pid)
    end)
  end

  defp subscribe(state, info, track, pid) do
    out = MediaStreamTrack.new(:audio, [info.sid])
    {:ok, sender} = PeerConnection.add_track(state.pc, out)
    Participant.subscribe(pid, track.sid)

    sub = %{
      publisher: pid,
      publisher_sid: info.sid,
      track: out,
      sender: sender.id,
      mime_type: track.mime_type,
      ready: false
    }

    %{state | subscriptions: Map.put(state.subscriptions, track.sid, sub)}
  end

  defp unsubscribe(state, sid) do
    {sub, subscriptions} = Map.pop(state.subscriptions, sid)
    Participant.unsubscribe(sub.publisher, sid)
    PeerConnection.remove_track(state.pc, sub.sender)
    %{state | subscriptions: subscriptions}
  end

  # Settles membership after a room restart: members that left while the
  # room was down are dropped, and new or changed members are applied.
  defp sync_members(state, members) do
    current = Map.new(members, fn {info, pid} -> {info.sid, {info, pid}} end)

    state =
      Enum.reduce(state.members, state, fn {sid, {info, _}}, s ->
        if Map.has_key?(current, sid) do
          s
        else
          Participant.notify(s.owner, {:participant_left, info})
          drop_publisher(%{s | members: Map.delete(s.members, sid)}, sid)
        end
      end)

    state =
      Enum.reduce(current, state, fn {sid, {info, pid}}, s ->
        cond do
          sid == s.info.sid -> s
          s.members[sid] == {info, pid} -> s
          true -> apply_member(s, sid, info, pid)
        end
      end)

    negotiate(state)
  end

  defp apply_member(state, sid, info, pid) do
    event =
      if Map.has_key?(state.members, sid), do: :participant_updated, else: :participant_joined

    Participant.notify(state.owner, {event, info})
    sync_publisher(%{state | members: Map.put(state.members, sid, {info, pid})}, info, pid)
  end

  defp drop_publisher(state, publisher_sid) do
    Enum.reduce(state.subscriptions, state, fn
      {sid, %{publisher_sid: ^publisher_sid}}, s -> unsubscribe(s, sid)
      _, s -> s
    end)
  end

  # After an exchange, each negotiated send-only transceiver can carry RTP
  # with the publisher's codec.
  defp ready_subscriptions(state) do
    transceivers = PeerConnection.get_transceivers(state.pc)

    subscriptions =
      Map.new(state.subscriptions, fn
        {sid, %{ready: false} = sub} -> {sid, ready(state.pc, sub, transceivers)}
        entry -> entry
      end)

    %{state | subscriptions: subscriptions}
  end

  defp ready(pc, sub, transceivers) do
    case Enum.find(transceivers, &(&1.sender.id == sub.sender and &1.mid != nil)) do
      nil ->
        sub

      tr ->
        codec =
          Enum.find(tr.codecs, &(String.downcase(&1.mime_type) == String.downcase(sub.mime_type)))

        if codec, do: PeerConnection.set_sender_codec(pc, tr.sender.id, codec)
        %{sub | ready: codec != nil}
    end
  end

  defp close(state, reason) do
    Participant.notify(state.owner, {:closed, reason})
    {:stop, :normal, state}
  end
end
