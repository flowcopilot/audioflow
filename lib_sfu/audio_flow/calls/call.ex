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

  After the call moves to this node, `:interrupted_turn` decides what happens
  to the user input of a turn that the old node did not finish: `:drop`
  (default) or `:retry_input` (submit it again as text, if it is newer than
  `:retry_window_ms`). Otherwise, `:resume_input` is submitted if it is set.
  """
  use GenServer, restart: :temporary
  require Logger
  alias AudioFlow.CallStore
  alias AudioFlow.SFU.Participant

  @vsn 1

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc "The current call record."
  def call(pid), do: GenServer.call(pid, :call)

  @doc """
  Hands the call over: waits up to `timeout` for the running turn, stops the
  SFU participant without leaving the room (it waits as away), and ends the
  lease now. Another node then claims the call at once.
  """
  def drain(pid, timeout), do: GenServer.call(pid, {:drain, timeout}, timeout + 5_000)

  @doc "Stops at once: another node holds the lease. Saves nothing."
  def lost(pid), do: GenServer.cast(pid, :lost)

  @doc "The identity of the agent participant of a call."
  def identity(call), do: "agent-" <> String.slice(call.id, 0, 8)

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    call = Keyword.fetch!(options, :call)

    # Under AudioFlow.Calls, the claimer finds local calls in this registry.
    if Process.whereis(AudioFlow.Calls.Registry),
      do: {:ok, _} = Registry.register(AudioFlow.Calls.Registry, call.id, nil)

    state = %{
      call: call,
      store: Keyword.fetch!(options, :store),
      owner: Keyword.fetch!(options, :owner),
      sfu: Keyword.get(options, :sfu, node()),
      interrupted_turn: Keyword.get(options, :interrupted_turn, :drop),
      retry_window_ms: Keyword.get(options, :retry_window_ms, 10_000),
      resume_input: Keyword.get(options, :resume_input),
      # A call that had an SFU participant before moves here from another node.
      moved?: call.resume_token != nil,
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

  def handle_call({:drain, timeout}, _from, state) do
    session = Participant.session(state.participant)
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_idle(session, deadline)
    # Stopping the participant process leaves its SFU participant away; the
    # next node resumes it with the saved token.
    Participant.stop(state.participant)
    :ok = CallStore.release(state.store, state.call.id, state.owner)
    {:stop, {:shutdown, :drained}, :ok, %{state | participant: nil}}
  catch
    :exit, _ -> {:stop, {:shutdown, :drained}, :ok, %{state | participant: nil}}
  end

  @impl true
  def handle_cast(:lost, state), do: {:stop, {:shutdown, :lease_lost}, state}

  @impl true
  def handle_info({Participant, pid, {:joined, join}}, %{participant: pid} = state) do
    members = Map.new(join.others, &{&1.sid, &1})
    state = %{state | members: members}

    changes =
      if join.resume_token == state.call.resume_token,
        do: %{},
        else: %{resume_token: join.resume_token}

    {input, changes} = moved_input(state, changes)

    with {:noreply, state} <- save_changes(state, changes) do
      if input, do: AudioFlow.submit(Participant.session(pid), %AudioFlow.Text{data: input})
      {:noreply, state}
    end
  end

  # Turn input, kept only with `interrupted_turn: :retry_input`.
  def handle_info(
        {Participant, pid, {:session, _turn, {:transcript, text}}},
        %{participant: pid, interrupted_turn: :retry_input} = state
      ),
      do: save(state, %{pending_input: %{"text" => text, "at" => CallStore.now()}})

  def handle_info({Participant, pid, {:session, _turn, event}}, %{participant: pid} = state)
      when elem(event, 0) in [:done, :cancelled, :error] do
    if state.call.pending_input,
      do: save(state, %{pending_input: nil}),
      else: {:noreply, state}
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

  # After a move: the interrupted input to retry, else the resume input.
  defp moved_input(%{moved?: false}, changes), do: {nil, changes}

  defp moved_input(state, changes) do
    pending = state.call.pending_input
    changes = if pending, do: Map.put(changes, :pending_input, nil), else: changes

    retry =
      state.interrupted_turn == :retry_input and pending != nil and
        CallStore.now() - pending["at"] <= state.retry_window_ms

    {if(retry, do: pending["text"], else: state.resume_input), changes}
  end

  defp save_changes(state, changes) when map_size(changes) == 0, do: {:noreply, state}
  defp save_changes(state, changes), do: save(state, changes)

  defp wait_idle(session, deadline) do
    unless AudioFlow.idle?(session) or System.monotonic_time(:millisecond) >= deadline do
      Process.sleep(50)
      wait_idle(session, deadline)
    end
  end

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
