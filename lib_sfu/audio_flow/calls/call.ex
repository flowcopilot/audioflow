defmodule AudioFlow.Calls.Call do
  @moduledoc """
  One durable call on this node: an `AudioFlow.SFU.Participant` whose session
  state is saved to an `AudioFlow.CallStore` after every commit.

  Start it with a call record that this node has claimed (`:call`), the
  `:store`, the lease `:owner` name, and optionally `:sfu`. The agent module
  in the record builds the session (`AudioFlow.Agent`). The session starts
  from the saved history and conversation state. If the record has a resume
  token, the participant takes back its SFU participant, so the room sees the
  same agent with the same track. The call joins after it starts, so a
  start does not block the process that starts it. A call that cannot join
  stops without ending its lease: the lease expires, and a node claims the
  call again, which backs off the retries.

  A save that fails with `:stale` means another node took the call: this
  process stops at once with `{:shutdown, :lease_lost}`. Any other save error
  (for example, a database that is down) keeps the newest snapshot and tries
  again with a growing delay; the call keeps running. When the last member
  other than agents leaves the room, the call ends (`status: :ended`) after
  `:leave_grace_ms` (5 000), so a user who reloads the page and joins again
  with the same identity keeps the call. It also ends when the room has had no
  such member for `:empty_timeout_ms` (60 000), for example a call whose user
  never joined.

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
  @max_retry_ms 5_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc "The current call record."
  def call(pid), do: GenServer.call(pid, :call)

  @doc """
  Hands the call over: waits up to `timeout` for the running turn, saves the
  commits that are still pending, stops the SFU participant without leaving
  the room (it waits as away), and ends the lease now. Another node then
  claims the call at once. Returns `{:error, reason}` if the lease did not
  end.
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
      empty_timeout: Keyword.get(options, :empty_timeout_ms, 60_000),
      leave_grace: Keyword.get(options, :leave_grace_ms, 5_000),
      empty_timer: nil,
      # A call that had an SFU participant before moves here from another node.
      moved?: call.resume_token != nil,
      participant: nil,
      members: %{},
      # Changes that no save has written yet, and the timer of the next try.
      pending: %{},
      save_failures: 0,
      retry_timer: nil,
      # The reason to stop with when the pending changes are saved.
      ending: nil,
      drain: nil
    }

    # The join can take seconds; the process that starts the call must not wait.
    {:ok, state, {:continue, :join}}
  end

  @impl true
  def handle_continue(:join, state) do
    with {:ok, agent} <- AudioFlow.Agent.module(state.call),
         {:ok, participant} <- join(state, agent) do
      {:noreply, %{state | participant: participant}}
    else
      {:error, reason} ->
        # The lease stays, so that no node starts this call again before it
        # expires. Another node may be able to run it (for example, with the
        # agent code).
        Logger.error("call #{state.call.id} did not start: #{inspect(reason)}")
        {:stop, {:shutdown, {:start_failed, reason}}, state}
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
        # Not a function: a closure fails after two hot code loads of this module.
        on_commit: {me, :commit}
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

  def handle_call({:drain, timeout}, from, %{drain: nil} = state) do
    timer = Process.send_after(self(), :drain_deadline, timeout)
    continue_drain(%{state | drain: %{froms: [from], timer: timer}})
  end

  def handle_call({:drain, _timeout}, from, %{drain: drain} = state),
    do: {:noreply, %{state | drain: %{drain | froms: [from | drain.froms]}}}

  @impl true
  def handle_cast(:lost, state), do: {:stop, {:shutdown, :lease_lost}, state}

  @impl true
  def handle_info({Participant, pid, {:joined, join}}, %{participant: pid} = state) do
    members = Map.new(join.others, &{&1.sid, &1})
    state = watch_empty(%{state | members: members})

    changes =
      if join.resume_token == state.call.resume_token,
        do: %{},
        else: %{resume_token: join.resume_token}

    {input, changes} = moved_input(state, changes)

    with {:noreply, state} <- save(state, changes) do
      if input, do: AudioFlow.submit(Participant.session(pid), %AudioFlow.Text{data: input})
      {:noreply, state}
    end
  end

  # Turn input, kept only with `interrupted_turn: :retry_input`.
  def handle_info(
        {Participant, pid, {:session, _turn, {:transcript, text}}},
        %{participant: pid, interrupted_turn: :retry_input} = state
      ),
      do: save(state, %{pending_input: %{"text" => text, "at" => CallStore.now(state.store)}})

  def handle_info({Participant, pid, {:session, _turn, event}}, %{participant: pid} = state)
      when elem(event, 0) in [:done, :cancelled, :error] do
    with {:noreply, state} <- save(state, %{pending_input: nil}), do: continue_drain(state)
  end

  def handle_info({:commit, snapshot}, state), do: save(state, snapshot)

  def handle_info(:retry_save, state), do: save(%{state | retry_timer: nil}, %{})

  def handle_info(:drain_deadline, %{drain: drain} = state) when drain != nil,
    do: finish_drain(state)

  def handle_info({Participant, pid, {event, info}}, %{participant: pid} = state)
      when event in [:participant_joined, :participant_updated],
      do: {:noreply, watch_empty(%{state | members: Map.put(state.members, info.sid, info)})}

  def handle_info({:empty, token}, %{empty_timer: {_, token}} = state),
    do: finish(state, :room_empty)

  # A user who reloads the page leaves and joins again. The call waits a short
  # time for that before it ends.
  def handle_info({Participant, pid, {:participant_left, info}}, %{participant: pid} = state) do
    state = %{state | members: Map.delete(state.members, info.sid)}
    {:noreply, watch_empty(state, state.leave_grace)}
  end

  def handle_info({Participant, pid, {:error, reason}}, %{participant: pid} = state) do
    Logger.warning("call #{state.call.id}: #{inspect(reason)}")
    {:noreply, state}
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

  defp users?(state), do: Enum.any?(Map.values(state.members), &(&1.kind != :agent))

  # Ends the call if no user is in the room for `delay`; a user cancels the wait.
  defp watch_empty(state, delay \\ nil) do
    case {users?(state), state.empty_timer} do
      {true, {timer, _}} ->
        Process.cancel_timer(timer)
        %{state | empty_timer: nil}

      {false, nil} ->
        token = make_ref()
        timer = Process.send_after(self(), {:empty, token}, delay || state.empty_timeout)
        %{state | empty_timer: {timer, token}}

      _ ->
        state
    end
  end

  # After a move: the interrupted input to retry, else the resume input.
  defp moved_input(%{moved?: false}, changes), do: {nil, changes}

  defp moved_input(state, changes) do
    pending = state.call.pending_input
    changes = if pending, do: Map.put(changes, :pending_input, nil), else: changes

    retry =
      state.interrupted_turn == :retry_input and pending != nil and
        CallStore.now(state.store) - pending["at"] <= state.retry_window_ms

    {if(retry, do: pending["text"], else: state.resume_input), changes}
  end

  # A drain waits for the session to be idle: the done, cancelled and error
  # events of the session call this again.
  defp continue_drain(%{drain: nil} = state), do: {:noreply, state}

  defp continue_drain(state),
    do: if(idle?(state), do: finish_drain(state), else: {:noreply, state})

  defp idle?(state) do
    AudioFlow.idle?(Participant.session(state.participant))
  catch
    :exit, _ -> true
  end

  defp finish_drain(%{drain: %{froms: froms, timer: timer}} = state) do
    Process.cancel_timer(timer)
    # The session sends a commit before it answers the idle check, so the
    # commits of all finished turns are in the mailbox now. Save them before the
    # lease ends: the next node starts from this snapshot.
    state = flush_commits(state)

    case write(state, %{}) do
      {:ok, saved} ->
        saved

      {:retry, unsaved} ->
        Logger.error("call #{state.call.id}: the last commit was not saved while draining")
        unsaved

      :stale ->
        state
    end
    |> release(froms)
  end

  defp flush_commits(state) do
    receive do
      {:commit, snapshot} -> flush_commits(%{state | pending: Map.merge(state.pending, snapshot)})
    after
      0 -> state
    end
  end

  defp release(state, froms) do
    # The participant stops without leaving the room; the next node resumes it
    # with the saved token.
    try do
      Participant.stop(state.participant)
    catch
      :exit, _ -> :ok
    end

    # Unregister first: a renewal must not extend a lease that ends now.
    if Process.whereis(AudioFlow.Calls.Registry),
      do: Registry.unregister(AudioFlow.Calls.Registry, state.call.id)

    reply =
      case CallStore.release(state.store, state.call.id, state.owner) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("call #{state.call.id}: the lease did not end: #{inspect(reason)}")
          {:error, {:release, reason}}
      end

    for from <- froms, do: GenServer.reply(from, reply)
    {:stop, {:shutdown, :drained}, %{state | participant: nil, drain: nil}}
  end

  # Writes the changes, and any that an earlier save left, in one save.
  # Returns `{:ok, state}`, `{:retry, state}` (the store failed; the changes
  # stay pending) or `:stale` (another node holds the call).
  defp write(state, changes) do
    pending = Map.merge(state.pending, changes)
    delta = delta(state.call, pending)

    if map_size(delta) == 0 do
      {:ok, cancel_retry(%{state | pending: %{}, save_failures: 0})}
    else
      call = state.call

      case CallStore.save(state.store, call.id, state.owner, call.version, delta) do
        {:ok, call} ->
          {:ok, cancel_retry(%{state | call: call, pending: %{}, save_failures: 0})}

        {:error, :stale} ->
          :stale

        {:error, reason} ->
          {:retry, retry_later(%{state | pending: pending}, reason)}
      end
    end
  end

  # Only the fields that differ from the saved record. New history that extends
  # the saved history is sent as an append.
  defp delta(call, changes) do
    for {key, value} <- changes, changed?(key, Map.fetch!(call, key), value), into: %{} do
      {key, if(key == :history, do: history_delta(call.history, value), else: value)}
    end
  end

  # The store keeps a conversation state name as a string.
  defp changed?(:conversation_state, old, new), do: name(old) != name(new)
  defp changed?(_key, old, new), do: old != new

  defp name(nil), do: nil
  defp name(state), do: to_string(state)

  defp history_delta([], history), do: history

  defp history_delta(saved, history) do
    if List.starts_with?(history, saved),
      do: {:append, Enum.drop(history, length(saved))},
      else: history
  end

  defp retry_later(state, reason) do
    failures = state.save_failures + 1
    delay = min(100 * Integer.pow(2, failures - 1), @max_retry_ms)

    Logger.warning(
      "call #{state.call.id}: save failed (#{inspect(reason)}), retrying in #{delay} ms"
    )

    state = cancel_retry(state)

    %{
      state
      | save_failures: failures,
        retry_timer: Process.send_after(self(), :retry_save, delay)
    }
  end

  defp cancel_retry(%{retry_timer: nil} = state), do: state

  defp cancel_retry(state) do
    Process.cancel_timer(state.retry_timer)
    %{state | retry_timer: nil}
  end

  defp save(state, changes) do
    case write(state, changes) do
      {:ok, %{ending: nil} = state} -> {:noreply, state}
      {:ok, state} -> {:stop, {:shutdown, state.ending}, state}
      {:retry, state} -> {:noreply, state}
      :stale -> lease_lost(state)
    end
  end

  defp lease_lost(state) do
    Logger.warning("call #{state.call.id}: lease lost, stopping")
    {:stop, {:shutdown, :lease_lost}, state}
  end

  # Ends the call, and stops once the store has the ended status.
  defp finish(state, reason), do: save(%{state | ending: reason}, %{status: :ended})
end
