defmodule AudioFlowSFU.Room do
  @moduledoc """
  Membership of one room. Media does not pass through this process: each
  participant forwards RTP to its subscribers directly.

  Members get `{AudioFlowSFU.Room, room, event}` messages, where `event` is
  `{:participant_joined, info, pid}`, `{:participant_updated, info, pid}`,
  `{:participant_left, info}`, `{:sync, [{info, pid}]}` or
  `:duplicate_identity` (the member was replaced by a newer join with the
  same identity).

  The room stops after `:empty_timeout_ms` with no members. If it crashes,
  its supervisor restarts it empty, and the members join it again with
  `rejoin/3`. After the last rejoin, the room sends `{:sync, members}` so
  that each member can drop the members that stopped meanwhile.
  """
  use GenServer, restart: :transient

  @vsn 1

  # One registry lookup, then two attempts through the supervisor.
  @attempts 3

  def child_spec(name) do
    %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [name]}, restart: :transient}
  end

  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: via(name))

  def via(name), do: {:via, Registry, {AudioFlowSFU.Registry, {:room, name}}}

  @doc "Returns the room process, if it runs."
  def whereis(name) do
    case Registry.lookup(AudioFlowSFU.Registry, {:room, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Adds a member. Starts the room when needed. Returns the room PID and the
  other members as `{info, pid}` pairs.
  """
  def join(name, info, pid, attempts \\ @attempts) do
    room = ensure_started(name, attempts)

    case GenServer.call(room, {:join, info, pid}) do
      {:ok, others} -> {:ok, room, others}
      {:error, _} = error -> error
    end
  catch
    # The room stopped between lookup and call (empty timeout).
    :exit, _ when attempts > 1 -> join(name, info, pid, attempts - 1)
  end

  @doc "Adds a member again after a room restart. Other members get no join event."
  def rejoin(name, info, pid, attempts \\ @attempts) do
    room = ensure_started(name, attempts)
    :ok = GenServer.call(room, {:rejoin, info, pid})
    {:ok, room}
  catch
    :exit, _ when attempts > 1 -> rejoin(name, info, pid, attempts - 1)
    :exit, reason -> {:error, reason}
  end

  def update(room, info), do: GenServer.cast(room, {:update, info, self()})
  def leave(room, sid), do: GenServer.call(room, {:leave, sid})
  def participants(room), do: GenServer.call(room, :participants)

  # A join to a running room is a registry read. A missing room goes through
  # the supervisor, which settles a race between two first joins. So does a
  # retry: the registry can still list a room that has just crashed, while the
  # supervisor has handled its exit and restarted it.
  defp ensure_started(name, attempts) do
    case attempts == @attempts && whereis(name) do
      pid when is_pid(pid) -> pid
      _ -> start_room(name)
    end
  end

  defp start_room(name) do
    case DynamicSupervisor.start_child(AudioFlowSFU.Rooms, {__MODULE__, name}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  @impl true
  def init(name) do
    state = %{
      name: name,
      members: %{},
      max: Application.fetch_env!(:audio_flow_sfu, :max_participants),
      empty_timeout: Application.fetch_env!(:audio_flow_sfu, :empty_timeout_ms),
      empty_timer: nil,
      sync_timer: nil
    }

    AudioFlowSFU.Telemetry.room(:start, name)
    {:ok, schedule_empty(state)}
  end

  @impl true
  def handle_call({:join, info, pid}, _from, state) do
    state = replace_identity(state, info.identity)

    if map_size(state.members) >= state.max do
      {:reply, {:error, :room_full}, state}
    else
      others = for {_, m} <- state.members, do: {m.info, m.pid}
      broadcast(state, {:participant_joined, info, pid})
      member = %{info: info, pid: pid, ref: Process.monitor(pid)}
      state = cancel_empty(%{state | members: Map.put(state.members, info.sid, member)})
      {:reply, {:ok, others}, state}
    end
  end

  def handle_call({:rejoin, info, pid}, _from, state) do
    member = %{info: info, pid: pid, ref: Process.monitor(pid)}
    state = cancel_empty(%{state | members: Map.put(state.members, info.sid, member)})
    {:reply, :ok, schedule_sync(state)}
  end

  def handle_call({:leave, sid}, _from, state), do: {:reply, :ok, remove(state, sid)}

  def handle_call(:participants, _from, state),
    do: {:reply, for({_, m} <- state.members, do: m.info), state}

  @impl true
  def handle_cast({:update, %{sid: sid} = info, pid}, state) do
    case state.members do
      %{^sid => %{pid: ^pid} = member} ->
        broadcast(state, {:participant_updated, info, pid}, sid)
        {:noreply, %{state | members: Map.put(state.members, sid, %{member | info: info})}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Enum.find(state.members, fn {_, m} -> m.ref == ref end) do
      {sid, _} -> {:noreply, remove(state, sid)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:empty, token}, %{empty_timer: {_, token}, members: members} = state)
      when map_size(members) == 0,
      do: {:stop, :normal, state}

  def handle_info(:sync, state) do
    members = for {_, m} <- state.members, do: {m.info, m.pid}
    broadcast(state, {:sync, members})
    {:noreply, %{state | sync_timer: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: AudioFlowSFU.Telemetry.room(:stop, state.name)

  # Members rejoin one by one after a restart. Waits for a quiet moment so
  # that one member list covers all of them.
  defp schedule_sync(state) do
    if state.sync_timer, do: Process.cancel_timer(state.sync_timer)
    %{state | sync_timer: Process.send_after(self(), :sync, 200)}
  end

  defp replace_identity(state, identity) do
    case Enum.find(state.members, fn {_, m} -> m.info.identity == identity end) do
      {sid, member} ->
        send(member.pid, {__MODULE__, state.name, :duplicate_identity})
        remove(state, sid)

      nil ->
        state
    end
  end

  defp remove(state, sid) do
    case Map.pop(state.members, sid) do
      {nil, _} ->
        state

      {member, members} ->
        Process.demonitor(member.ref, [:flush])
        state = %{state | members: members}
        broadcast(state, {:participant_left, member.info})
        schedule_empty(state)
    end
  end

  defp broadcast(state, event, except \\ nil) do
    for {sid, m} <- state.members, sid != except, do: send(m.pid, {__MODULE__, state.name, event})
    :ok
  end

  defp schedule_empty(%{members: members} = state) when map_size(members) > 0, do: state

  defp schedule_empty(state) do
    state = cancel_empty(state)
    token = make_ref()
    timer = Process.send_after(self(), {:empty, token}, state.empty_timeout)
    %{state | empty_timer: {timer, token}}
  end

  defp cancel_empty(%{empty_timer: nil} = state), do: state

  defp cancel_empty(%{empty_timer: {timer, _}} = state) do
    Process.cancel_timer(timer)
    %{state | empty_timer: nil}
  end
end
