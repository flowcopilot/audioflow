defmodule AudioFlow.Calls.Call do
  @moduledoc """
  One durable call on this node: an `AudioFlow.SFU.Participant` whose session
  state is saved to an `AudioFlow.CallStore` after every commit.

  Start it with a call record that this node has claimed (`:call`), the
  `:store`, the lease `:owner` name, and optionally `:sfu`. The agent module
  in the record builds the session (`AudioFlow.Agent`). The session starts
  from the saved history and conversation state. If the record has a resume
  token, the participant takes back its SFU participant, so the room sees the
  same agent with the same track.

  A save that fails with `:stale` means another node took the call: this
  process stops at once with `{:shutdown, :lease_lost}`. When no member
  other than agents is left in the room, the call ends (`status: :ended`).
  """
  use GenServer, restart: :temporary
  require Logger
  alias AudioFlow.CallStore
  alias AudioFlow.SFU.Participant

  @vsn 1

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc "The current call record."
  def call(pid), do: GenServer.call(pid, :call)

  @doc "The identity of the agent participant of a call."
  def identity(call), do: "agent-" <> String.slice(call.id, 0, 8)

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    call = Keyword.fetch!(options, :call)

    state = %{
      call: call,
      store: Keyword.fetch!(options, :store),
      owner: Keyword.fetch!(options, :owner),
      sfu: Keyword.get(options, :sfu, node()),
      participant: nil,
      members: %{}
    }

    with {:ok, agent} <- AudioFlow.Agent.module(call),
         {:ok, participant} <- join(state, agent) do
      {:ok, %{state | participant: participant}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # Takes back the SFU participant when the record has a resume token. If it
  # is gone (the away timeout ended it), joins as a new participant.
  defp join(state, agent) do
    call = state.call
    me = self()

    session =
      agent.session_options(call)
      |> Keyword.merge(
        restore: %{
          history: call.history,
          conversation_state: call.conversation_state,
          turns: call.turns
        },
        on_commit: &send(me, {:commit, &1})
      )

    options =
      agent_options(agent, call)
      |> Keyword.merge(
        room: call.room,
        identity: identity(call),
        session: session,
        sfu: state.sfu,
        owner: me
      )

    resume = if call.resume_token, do: [resume_token: call.resume_token], else: []
    join = Keyword.get(options, :join, [])

    case Participant.start_link(Keyword.put(options, :join, join ++ resume)) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :unknown_session} when resume != [] ->
        Participant.start_link(Keyword.put(options, :join, join))

      error ->
        error
    end
  end

  defp agent_options(agent, call) do
    if function_exported?(agent, :participant_options, 1),
      do: agent.participant_options(call),
      else: []
  end

  @impl true
  def handle_call(:call, _from, state), do: {:reply, state.call, state}

  @impl true
  def handle_info({Participant, pid, {:joined, join}}, %{participant: pid} = state) do
    members = Map.new(join.others, &{&1.sid, &1})
    state = %{state | members: members}

    if join.resume_token == state.call.resume_token,
      do: {:noreply, state},
      else: save(state, %{resume_token: join.resume_token})
  end

  def handle_info({:commit, snapshot}, state), do: save(state, snapshot)

  def handle_info({Participant, pid, {event, info}}, %{participant: pid} = state)
      when event in [:participant_joined, :participant_updated],
      do: {:noreply, %{state | members: Map.put(state.members, info.sid, info)}}

  def handle_info({Participant, pid, {:participant_left, info}}, %{participant: pid} = state) do
    state = %{state | members: Map.delete(state.members, info.sid)}

    if Enum.any?(Map.values(state.members), &(&1.kind != :agent)),
      do: {:noreply, state},
      else: finish(state, :room_empty)
  end

  def handle_info({Participant, pid, {:closed, reason}}, %{participant: pid} = state),
    do: {:stop, {:shutdown, {:closed, reason}}, state}

  def handle_info({:EXIT, pid, reason}, %{participant: pid} = state),
    do: {:stop, {:shutdown, {:participant_exit, reason}}, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{participant: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Participant.stop(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_, _), do: :ok

  defp save(state, changes) do
    call = state.call

    case CallStore.save(state.store, call.id, state.owner, call.version, changes) do
      {:ok, call} ->
        {:noreply, %{state | call: call}}

      {:error, :stale} ->
        Logger.warning("call #{call.id}: lease lost, stopping")
        {:stop, {:shutdown, :lease_lost}, state}
    end
  end

  defp finish(state, reason) do
    case save(state, %{status: :ended}) do
      {:noreply, state} -> {:stop, {:shutdown, reason}, state}
      stop -> stop
    end
  end
end
