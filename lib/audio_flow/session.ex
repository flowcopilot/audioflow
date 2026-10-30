defmodule AudioFlow.Session do
  @moduledoc """
  One active turn per session. Busy sessions reject input instead of queueing it.

  Options: `:stt`, `:llm`, `:tts` adapter tuples; `:owner`; `:timeout_ms`
  (30,000); `:max_input_bytes` (960,000); `:max_events` (1,024).
  The session stops when its owner exits. Interrupted turns cannot deliver
  further output. Cancellation stops the caller task, but an inference engine
  may still finish a batch already submitted to shared hardware.
  """
  use GenServer, restart: :temporary
  alias AudioFlow.{Adapter, Audio}

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(options, :owner)
    adapters = Map.new([:stt, :llm, :tts], &{&1, Keyword.fetch!(options, &1)})

    limits =
      Map.new([timeout_ms: 30_000, max_input_bytes: 960_000, max_events: 1_024], fn {key, default} ->
        value = Keyword.get(options, key, default)

        if not (is_integer(value) and value > 0),
          do: raise(ArgumentError, "#{key} must be positive")

        {key, value}
      end)

    {:ok,
     %{
       owner: owner,
       owner_ref: Process.monitor(owner),
       adapters: adapters,
       limits: limits,
       active: nil
     }}
  end

  @impl true
  def handle_call({:submit, audio}, _from, state) do
    cond do
      not Audio.valid?(audio) ->
        {:reply, {:error, :invalid_audio}, state}

      byte_size(audio.data) > state.limits.max_input_bytes ->
        {:reply, {:error, :input_too_large}, state}

      state.active != nil ->
        {:reply, {:error, :busy}, state}

      true ->
        session = self()
        turn = make_ref()
        started = now()

        task =
          Task.Supervisor.async_nolink(AudioFlow.Tasks, fn ->
            pipeline(session, turn, audio, state.adapters)
          end)

        timer = Process.send_after(self(), {:timeout, turn}, state.limits.timeout_ms)
        active = %{turn: turn, task: task, timer: timer, started: started, first: %{}, events: 0}
        {:reply, {:ok, turn}, %{state | active: active}}
    end
  end

  def handle_call(:cancel, _from, %{active: nil} = state), do: {:reply, :ok, state}

  def handle_call(:cancel, _from, state) do
    kill(state.active)
    notify(state, {:cancelled, metrics(state.active)})
    {:reply, :ok, %{state | active: nil}}
  end

  def handle_call({:emit, turn, kind, value}, _from, %{active: %{turn: turn} = active} = state) do
    cond do
      not valid_output?(kind, value) ->
        {:reply, {:error, :invalid_output}, state}

      active.events >= state.limits.max_events ->
        {:reply, {:error, :output_limit}, state}

      true ->
        first = Map.put_new(active.first, kind, now() - active.started)
        notify(state, {kind, value})
        {:reply, :ok, %{state | active: %{active | first: first, events: active.events + 1}}}
    end
  end

  def handle_call({:emit, _, _, _}, _from, state), do: {:reply, {:error, :stale_turn}, state}

  @impl true
  def handle_info({ref, result}, %{active: %{task: %{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(state.active.timer)

    event =
      case result do
        :ok -> {:done, metrics(state.active)}
        {:error, reason} -> {:error, reason, metrics(state.active)}
      end

    notify(state, event)
    {:noreply, %{state | active: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, reason}, %{active: %{task: %{ref: ref}}} = state) do
    Process.cancel_timer(state.active.timer)
    notify(state, {:error, {:task_exit, reason}, metrics(state.active)})
    {:noreply, %{state | active: nil}}
  end

  def handle_info({:timeout, turn}, %{active: %{turn: turn}} = state) do
    kill(state.active)
    notify(state, {:error, :timeout, metrics(state.active)})
    {:noreply, %{state | active: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{active: nil}), do: :ok
  def terminate(_, state), do: kill(state.active)

  defp pipeline(session, turn, audio, adapters) do
    emit = fn kind, value ->
      case GenServer.call(session, {:emit, turn, kind, value}) do
        :ok -> :ok
        {:error, reason} -> throw(reason)
      end
    end

    # STT chunks are one utterance. Do not answer each partial transcript.
    key = make_ref()
    Process.put(key, [])

    try do
      Adapter.run(adapters.stt, audio, fn text ->
        emit.(:transcript, text)
        Process.put(key, [text | Process.get(key)])
        :ok
      end)

      transcript = Process.get(key) |> Enum.reverse() |> Enum.join("") |> String.trim()

      if transcript != "" do
        Adapter.run(adapters.llm, transcript, fn text ->
          emit.(:text, text)
          Adapter.run(adapters.tts, text, &emit.(:audio, &1))
        end)
      end

      :ok
    rescue
      error -> {:error, {:exception, Exception.message(error)}}
    catch
      reason -> {:error, reason}
    after
      Process.delete(key)
    end
  end

  defp valid_output?(:audio, audio), do: Audio.valid?(audio)
  defp valid_output?(kind, text) when kind in [:text, :transcript], do: is_binary(text)
  defp now, do: System.monotonic_time(:microsecond)
  defp notify(state, event), do: send(state.owner, {AudioFlow, self(), state.active.turn, event})

  defp kill(active) do
    Process.cancel_timer(active.timer)
    Process.exit(active.task.pid, :kill)
    Process.demonitor(active.task.ref, [:flush])
    :ok
  end

  defp metrics(active) do
    %{
      duration_us: now() - active.started,
      first_transcript_us: active.first[:transcript],
      first_text_us: active.first[:text],
      first_audio_us: active.first[:audio],
      events: active.events
    }
  end
end
