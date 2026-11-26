defmodule AudioFlowSFU.Participant.Native do
  @moduledoc """
  A participant for a BEAM process, usually an agent on another node of a
  trusted Erlang cluster. Media goes as Erlang messages, with no ICE, DTLS or
  SRTP. Use it through `AudioFlowSFU.Native`.

  When the agent process or its node stops, the participant stays in the
  room as `:away` for `:away_timeout_ms`, with its tracks still published.
  A join with the same identity and the resume token takes it back.
  """
  use GenServer, restart: :temporary

  alias AudioFlowSFU.Participant
  alias AudioFlowSFU.Room
  alias AudioFlowSFU.Telemetry

  @vsn 1
  @tag :audio_flow_sfu
  @protocol 1

  def start(room, identity, agent, options) do
    spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [{room, identity, agent, options}]},
      restart: :temporary
    }

    with {:ok, pid} <- DynamicSupervisor.start_child(AudioFlowSFU.Participants, spec),
         do: {:ok, GenServer.call(pid, :join_info)}
  end

  def start_link(argument), do: GenServer.start_link(__MODULE__, argument)

  def resume(token, identity, agent) do
    case Registry.lookup(AudioFlowSFU.Registry, {:resume, token}) do
      [{pid, _}] -> GenServer.call(pid, {:resume, identity, agent})
      [] -> {:error, :unknown_session}
    end
  catch
    :exit, _ -> {:error, :unknown_session}
  end

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  @impl true
  def init({room, identity, agent, options}) do
    grants = %{
      identity: identity,
      name: Keyword.get(options, :name, identity),
      metadata: Keyword.get(options, :metadata, ""),
      kind: Keyword.get(options, :kind, :agent),
      room: room,
      can_publish: true,
      can_subscribe: true,
      can_publish_data: true
    }

    info = Participant.info(grants)
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    {:ok, _} = Registry.register(AudioFlowSFU.Registry, {:resume, token}, nil)
    {:ok, _} = Registry.register(AudioFlowSFU.Registry, {:participant, info.sid}, nil)

    case Room.join(room, info, self()) do
      {:ok, room_pid, others} ->
        Telemetry.participant(:join, info, room)

        state = %{
          grants: grants,
          info: info,
          agent: agent,
          agent_ref: Process.monitor(agent),
          resume_token: token,
          away_timeout:
            Keyword.get_lazy(options, :away_timeout_ms, fn ->
              Application.fetch_env!(:audio_flow_sfu, :away_timeout_ms)
            end),
          away_timer: nil,
          room: room_pid,
          room_ref: Process.monitor(room_pid),
          members: %{},
          # Track SID => publisher pid.
          subscriptions: %{},
          # Own track SID => %{subscriber pid => monitor ref}.
          subscribers: %{}
        }

        {:ok, Enum.reduce(others, state, fn {i, pid}, s -> put_member(s, i, pid) end)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:join_info, _from, state), do: {:reply, join_info(state), state}

  def handle_call({:resume, identity, agent}, _from, %{grants: %{identity: identity}} = state) do
    if state.agent_ref, do: Process.demonitor(state.agent_ref, [:flush])
    if state.agent, do: notify(state, {:closed, :resumed_elsewhere})
    if state.away_timer, do: Process.cancel_timer(elem(state.away_timer, 0))
    Telemetry.participant(:resume, state.info, state.grants.room)

    state = %{state | agent: agent, agent_ref: Process.monitor(agent), away_timer: nil}
    state = update_info(state, %{state.info | state: :active})
    {:reply, {:ok, join_info(state)}, state}
  end

  def handle_call({:resume, _, _}, _from, state),
    do: {:reply, {:error, :identity_mismatch}, state}

  def handle_call({:publish_track, mime_type, name}, _from, state) do
    track = Participant.track(mime_type, name)
    state = update_info(state, %{state.info | tracks: state.info.tracks ++ [track]})
    Telemetry.track(:publish, track, state.info, state.grants.room)
    {:reply, {:ok, track}, state}
  end

  def handle_call(:leave, _from, state), do: {:stop, :normal, :ok, state}

  @impl true
  # Audio from the agent: forwarded to the subscribers of its own track.
  def handle_info({@tag, @protocol, {:rtp, sid, rtp}}, state) do
    case state.subscribers do
      %{^sid => subscribers} ->
        packet =
          ExRTP.Packet.new(rtp.payload,
            sequence_number: rtp.sequence_number,
            timestamp: rtp.timestamp,
            marker: Map.get(rtp, :marker, false)
          )

        Participant.forward(Map.keys(subscribers), sid, packet)
        |> Telemetry.dropped(sid, state.info, state.grants.room)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  # Audio for the agent.
  def handle_info({Participant, :rtp, sid, packet}, %{agent: agent} = state) when agent != nil do
    rtp = %{
      sequence_number: packet.sequence_number,
      timestamp: packet.timestamp,
      marker: packet.marker,
      payload: packet.payload
    }

    if :erlang.send(agent, {@tag, @protocol, self(), {:rtp, sid, rtp}}, [:nosuspend]) ==
         :nosuspend,
       do: Telemetry.dropped(1, sid, state.info, state.grants.room)

    {:noreply, state}
  end

  def handle_info({Participant, :rtp, _sid, _packet}, state), do: {:noreply, state}

  def handle_info({Participant, :subscribe, sid, pid}, state) do
    if Enum.any?(state.info.tracks, &(&1.sid == sid)) do
      subscribers = Map.get(state.subscribers, sid, %{})

      subscribers =
        Map.put_new_lazy(subscribers, pid, fn -> Process.monitor(pid) end)

      {:noreply, %{state | subscribers: Map.put(state.subscribers, sid, subscribers)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({Participant, :unsubscribe, sid, pid}, state),
    do: {:noreply, drop_subscriber(state, sid, pid)}

  def handle_info({Room, _, {event, info, pid}}, state)
      when event in [:participant_joined, :participant_updated] do
    notify(state, {event, info})
    {:noreply, put_member(state, info, pid)}
  end

  def handle_info({Room, _, {:participant_left, info}}, state) do
    notify(state, {:participant_left, info})
    {:noreply, drop_member(state, info.sid)}
  end

  def handle_info({Room, _, {:sync, members}}, state) do
    current = Map.new(members, fn {info, pid} -> {info.sid, {info, pid}} end)

    state =
      Enum.reduce(Map.keys(state.members), state, fn sid, s ->
        if Map.has_key?(current, sid), do: s, else: drop_member(s, sid)
      end)

    state =
      Enum.reduce(current, state, fn
        {sid, _}, s when sid == s.info.sid -> s
        {_, {info, pid}}, s -> put_member(s, info, pid)
      end)

    {:noreply, state}
  end

  def handle_info({Room, _, :duplicate_identity}, state), do: close(state, :duplicate_identity)

  # The agent or its node stopped: wait for a resume.
  def handle_info({:DOWN, ref, :process, _, _}, %{agent_ref: ref} = state) do
    Telemetry.participant(:away, state.info, state.grants.room)
    token = make_ref()
    timer = Process.send_after(self(), {:away_timeout, token}, state.away_timeout)
    state = %{state | agent: nil, agent_ref: nil, away_timer: {timer, token}}
    {:noreply, update_info(state, %{state.info | state: :away})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{room_ref: ref} = state) do
    case Room.rejoin(state.grants.room, state.info, self()) do
      {:ok, room} -> {:noreply, %{state | room: room, room_ref: Process.monitor(room)}}
      {:error, reason} -> close(state, {:room_down, reason})
    end
  end

  def handle_info({:DOWN, _, :process, pid, _}, state) do
    state =
      Enum.reduce(Map.keys(state.subscribers), state, fn sid, s ->
        drop_subscriber(s, sid, pid)
      end)

    {:noreply, state}
  end

  def handle_info({:away_timeout, token}, %{away_timer: {_, token}} = state),
    do: close(state, :away_timeout)

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for track <- state.info.tracks,
        do: Telemetry.track(:unpublish, track, state.info, state.grants.room)

    Telemetry.participant(:leave, state.info, state.grants.room)
  end

  defp join_info(state) do
    %{
      participant: self(),
      info: state.info,
      others: for({_, {info, _}} <- state.members, do: info),
      resume_token: state.resume_token
    }
  end

  # Subscribes to every track of a member and drops removed tracks.
  defp put_member(state, info, pid) do
    current = MapSet.new(info.tracks, & &1.sid)

    subscriptions =
      Enum.reduce(state.subscriptions, state.subscriptions, fn
        {sid, ^pid}, subs ->
          if sid in current do
            subs
          else
            Participant.unsubscribe(pid, sid)
            Map.delete(subs, sid)
          end

        _, subs ->
          subs
      end)

    subscriptions =
      Enum.reduce(info.tracks, subscriptions, fn track, subs ->
        if Map.has_key?(subs, track.sid) do
          subs
        else
          Participant.subscribe(pid, track.sid)
          Map.put(subs, track.sid, pid)
        end
      end)

    %{
      state
      | members: Map.put(state.members, info.sid, {info, pid}),
        subscriptions: subscriptions
    }
  end

  defp drop_member(state, sid) do
    case Map.pop(state.members, sid) do
      {nil, _} ->
        state

      {{_info, pid}, members} ->
        subscriptions = Map.reject(state.subscriptions, fn {_, publisher} -> publisher == pid end)
        %{state | members: members, subscriptions: subscriptions}
    end
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

  defp update_info(state, info) do
    info = %{info | version: info.version + 1}
    Room.update(state.room, info)
    %{state | info: info}
  end

  defp notify(%{agent: nil}, _event), do: :ok
  defp notify(state, event), do: send(state.agent, {@tag, @protocol, self(), event})

  defp close(state, reason) do
    notify(state, {:closed, reason})
    {:stop, :normal, state}
  end
end
