defmodule AudioFlow.Playback do
  @moduledoc """
  Bounded, demand-driven Membrane output for one conversation.

  Start with `sink: sink_element` and attach `{AudioFlow.Playback, pid}` as the
  session's `:output`. The sink can be a PortAudio device or an application
  transport. No device is opened until the first PCM chunk arrives.

  `:max_bytes` bounds queued PCM (default 96,000). One extra chunk of at most
  that size can wait for capacity. The turn worker blocks while it waits;
  cancellation remains available. Downstream queues and device buffers have
  their own limits.

  One Membrane pipeline serves all turns of the output. It starts on the first
  chunk and restarts only when the sample rate changes or the session ends.
  Turn boundaries do not open or close the sink. Flush drops queued PCM, rotates
  the turn key and acknowledges at once. If audio already reached the sink, the
  pipeline is told to stop and the next turn starts a fresh one; the stop is
  asynchronous, so it is off the session's call path. Audio already inside a
  sink's own buffer can play until that stop completes; measure acoustic stop
  time separately. Old turn keys cannot send output after a flush.

  The observer (default: caller) receives
  `{AudioFlow.Playback, pid, key, event}`. Events include pipeline start,
  sink notifications, drain, failure, and flush control time in microseconds.
  """
  use GenServer
  @behaviour AudioFlow.Output
  alias AudioFlow.Audio

  def start_link(options),
    do: GenServer.start_link(__MODULE__, Keyword.put_new(options, :observer, self()))

  @impl AudioFlow.Output
  def start_turn(pid, key), do: GenServer.call(pid, {:start_turn, key}, :infinity)
  @impl AudioFlow.Output
  def push(pid, key, audio), do: GenServer.call(pid, {:push, key, audio}, :infinity)
  @impl AudioFlow.Output
  def finish(pid, key), do: GenServer.call(pid, {:finish, key})
  @impl AudioFlow.Output
  def flush(pid, key), do: GenServer.call(pid, {:flush, key}, :infinity)

  @doc """
  Acknowledge an endpoint-rendered cumulative PCM offset in nanoseconds.
  Invoke from the transport driver, not from a sink demand/enqueue callback.
  PortAudio does not provide this acknowledgement automatically.
  """
  def acknowledge(pid, {session, turn} = key, nanoseconds) do
    with :ok <- GenServer.call(pid, {:played, key, nanoseconds}) do
      AudioFlow.Output.acknowledge(session, turn, nanoseconds)
    end
  end

  def stats(pid), do: GenServer.call(pid, :stats)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    max_bytes = Keyword.get(options, :max_bytes, 96_000)

    unless is_integer(max_bytes) and max_bytes >= 2,
      do: raise(ArgumentError, "max_bytes must be at least 2")

    {:ok,
     %{
       sink: Keyword.fetch!(options, :sink),
       observer: Keyword.fetch!(options, :observer),
       max_bytes: max_bytes,
       session: nil,
       session_ref: nil,
       key: nil,
       pipeline: nil,
       queue: :queue.new(),
       bytes: 0,
       playout: AudioFlow.Playout.new(),
       waiting: nil,
       demand: nil,
       turn_rate: nil,
       finished?: false,
       dispatched?: false,
       draining: nil,
       last_flush_us: nil,
       started: nil,
       first_buffer_us: nil
     }}
  end

  @impl true
  def handle_call({:start_turn, {session, turn} = key}, _from, state)
      when is_pid(session) and is_reference(turn) do
    if state.session && state.session != session do
      {:reply, {:error, :output_in_use}, state}
    else
      state = state |> abandon() |> monitor_session(session)
      {:reply, :ok, %{state | key: key, started: System.monotonic_time(:microsecond)}}
    end
  end

  def handle_call({:push, key, audio}, from, %{key: key, finished?: false} = state)
      when key != nil do
    case {push_error(audio, state), audio.data} do
      {nil, <<>>} -> {:reply, :ok, state}
      {nil, data} -> accept_push(%{audio | data: :binary.copy(data)}, from, state)
      {reason, _} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:push, _, _}, _from, state), do: {:reply, {:error, :stale_turn}, state}

  def handle_call({:finish, key}, _from, %{key: key} = state) do
    if not state.finished? and not state.dispatched? and state.bytes == 0,
      do: notify(state, key, :drained)

    {:reply, :ok, serve(%{state | finished?: true})}
  end

  def handle_call({:finish, _}, _from, state), do: {:reply, {:error, :stale_turn}, state}

  def handle_call({:flush, key}, _from, %{key: key} = state) do
    started = System.monotonic_time(:microsecond)

    state = abandon(state)
    us = System.monotonic_time(:microsecond) - started
    notify(state, key, {:flushed, %{control_us: us}})
    {:reply, :ok, %{state | last_flush_us: us}}
  end

  def handle_call({:flush, _}, _from, state), do: {:reply, :ok, state}

  def handle_call({:played, key, ns}, _from, %{key: key} = state) when key != nil do
    case AudioFlow.Playout.acknowledge(state.playout, ns) do
      {:ok, playout} ->
        notify(state, key, {:played_offset, ns})
        {:reply, :ok, %{state | playout: playout}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:played, _, _}, _from, state),
    do: {:reply, {:error, :stale_turn}, state}

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       played_ns: state.playout.played,
       dispatched_ns: state.playout.emitted,
       queued_bytes: state.bytes,
       blocked?: state.waiting != nil,
       key: state.key,
       pipeline: state.pipeline && state.pipeline.pid,
       last_flush_us: state.last_flush_us
     }, state}
  end

  @impl true
  def handle_info({:take_pcm, id, source, request}, %{pipeline: %{id: id}} = state) do
    {:noreply, serve(%{state | demand: {source, request}})}
  end

  def handle_info({:take_pcm, _id, source, request}, state) do
    send(source, {:pcm, request, :end_of_stream})
    {:noreply, state}
  end

  def handle_info(
        {:playback_notification, id, child, notification},
        %{pipeline: %{id: id}} = state
      ) do
    notify(state, state.key, {:sink_notification, child, notification})
    {:noreply, state}
  end

  def handle_info({:playback_drained, id}, %{pipeline: %{id: id}, draining: key} = state)
      when key != nil do
    notify(state, key, :drained)
    {:noreply, %{state | draining: nil, dispatched?: false}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{session_ref: ref} = state) do
    state = state |> abandon(true) |> Map.merge(%{session: nil, session_ref: nil})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{waiting: %{ref: ref}} = state),
    do: {:noreply, %{state | waiting: nil}}

  def handle_info({:DOWN, ref, :process, _, reason}, %{pipeline: %{ref: ref}} = state) do
    notify(state, state.key, {:failed, reason})

    if state.waiting do
      Process.demonitor(state.waiting.ref, [:flush])
      GenServer.reply(state.waiting.from, {:error, {:pipeline_exit, reason}})
    end

    {:noreply, %{reset_turn(state) | pipeline: nil, key: nil, waiting: nil, demand: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: stop_pipeline(state.pipeline)

  defp monitor_session(%{session_ref: nil} = state, session),
    do: %{state | session: session, session_ref: Process.monitor(session)}

  defp monitor_session(state, _session), do: state

  defp push_error(audio, state) do
    cond do
      not Audio.valid?(audio) -> :invalid_audio
      byte_size(audio.data) > state.max_bytes -> :chunk_too_large
      state.turn_rate && state.turn_rate != audio.sample_rate -> :sample_rate_changed
      state.waiting -> :producer_busy
      true -> nil
    end
  end

  defp accept_push(audio, from, state) do
    case ensure_pipeline(state, audio.sample_rate) do
      {:ok, state} -> queue_or_wait(audio, from, %{state | turn_rate: audio.sample_rate})
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp queue_or_wait(audio, from, state) do
    if state.bytes + byte_size(audio.data) <= state.max_bytes do
      {:reply, :ok, state |> enqueue(audio) |> serve()}
    else
      ref = Process.monitor(elem(from, 0))

      notify(
        state,
        state.key,
        {:backpressure, %{queued_bytes: state.bytes, waiting_bytes: byte_size(audio.data)}}
      )

      {:noreply, %{state | waiting: %{from: from, audio: audio, ref: ref}}}
    end
  end

  defp enqueue(state, audio),
    do: %{
      state
      | queue: :queue.in(audio, state.queue),
        bytes: state.bytes + byte_size(audio.data)
    }

  defp serve(%{demand: nil} = state), do: state

  defp serve(state) do
    {source, request} = state.demand

    case :queue.out(state.queue) do
      {{:value, audio}, queue} ->
        state =
          if state.first_buffer_us == nil do
            us = System.monotonic_time(:microsecond) - state.started
            notify(state, state.key, {:first_buffer, %{elapsed_us: us}})
            %{state | first_buffer_us: us}
          else
            state
          end

        send(source, {:pcm, request, audio})

        state = %{
          state
          | queue: queue,
            bytes: state.bytes - byte_size(audio.data),
            demand: nil,
            dispatched?: true,
            playout: AudioFlow.Playout.audio(state.playout, audio)
        }

        release_producer(state)

      {:empty, _} when state.finished? and state.dispatched? and state.draining == nil ->
        send(source, {:pcm, request, :end_of_turn})
        %{state | demand: nil, draining: state.key}

      {:empty, _} when state.finished? ->
        state

      {:empty, _} ->
        state
    end
  end

  defp release_producer(%{waiting: nil} = state), do: state

  defp release_producer(state) do
    pending = state.waiting

    if state.bytes + byte_size(pending.audio.data) <= state.max_bytes do
      Process.demonitor(pending.ref, [:flush])
      GenServer.reply(pending.from, :ok)
      enqueue(%{state | waiting: nil}, pending.audio)
    else
      state
    end
  end

  defp ensure_pipeline(%{pipeline: %{rate: rate}} = state, rate), do: {:ok, state}

  defp ensure_pipeline(state, rate) do
    state = retire(state)
    id = make_ref()
    options = %{playback: self(), id: id, rate: rate, sink: state.sink}

    case Membrane.Pipeline.start_link(AudioFlow.PlaybackPipeline, options) do
      {:ok, supervisor, pipeline} ->
        notify(state, state.key, {:pipeline_started, pipeline})

        {:ok,
         %{
           state
           | pipeline: %{
               pid: pipeline,
               supervisor: supervisor,
               ref: Process.monitor(supervisor),
               id: id,
               rate: rate
             }
         }}

      {:error, reason} ->
        {:error, {:pipeline_start, reason}, state}
    end
  end

  # Ends the current turn without waiting for the pipeline. The pipeline is
  # kept unless audio already reached the sink (or `retire?` is set), because
  # only a stop can discard what the sink buffers.
  defp abandon(state, retire? \\ false) do
    if state.waiting do
      Process.demonitor(state.waiting.ref, [:flush])
      GenServer.reply(state.waiting.from, {:error, :stale_turn})
    end

    state = if retire? or state.dispatched?, do: retire(state), else: state
    %{reset_turn(state) | key: nil, waiting: nil}
  end

  defp reset_turn(state),
    do: %{
      state
      | queue: :queue.new(),
        bytes: 0,
        playout: AudioFlow.Playout.new(),
        turn_rate: nil,
        finished?: false,
        dispatched?: false,
        draining: nil,
        first_buffer_us: nil
    }

  # Asks the pipeline's supervisor to shut down and forgets it. The caller is
  # the supervisor's parent, so the exit signal is a shutdown request.
  defp retire(%{pipeline: nil} = state), do: state

  defp retire(%{pipeline: pipeline} = state) do
    Process.demonitor(pipeline.ref, [:flush])
    Process.exit(pipeline.supervisor, :shutdown)
    %{state | pipeline: nil, demand: nil, dispatched?: false, draining: nil}
  end

  defp stop_pipeline(nil), do: :ok

  defp stop_pipeline(pipeline) do
    if Process.alive?(pipeline.supervisor),
      do: Supervisor.stop(pipeline.supervisor, :shutdown, 5000)

    :ok
  catch
    :exit, _ -> :ok
  end

  defp notify(state, key, event), do: send(state.observer, {__MODULE__, self(), key, event})
end
