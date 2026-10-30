defmodule AudioFlow.Playback do
  @moduledoc """
  Bounded, demand-driven Membrane output for one conversation.

  Start with `sink: sink_element` and attach `{AudioFlow.Playback, pid}` as the
  session's `:output`. The sink can be a PortAudio device or an application
  transport. No device is opened until the first PCM chunk arrives.

  `:max_bytes` bounds queued PCM (default 96,000). One extra chunk of at most
  that size can wait for capacity. The turn worker blocks while it waits;
  cancellation remains available. Downstream queues and device buffers have
  their own limits. Flush closes the old pipeline before it acknowledges.
  Device close can drain a short native buffer; acoustic stop time must be
  measured separately. Old turn keys cannot send output after a flush.

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
       waiting: nil,
       demand: nil,
       rate: nil,
       finished?: false,
       draining?: false,
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
      case clear(state) do
        {:ok, state} ->
          state =
            if state.session_ref,
              do: state,
              else: %{state | session: session, session_ref: Process.monitor(session)}

          {:reply, :ok, %{state | key: key, started: System.monotonic_time(:microsecond)}}

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:push, key, audio}, from, %{key: key, finished?: false} = state)
      when key != nil do
    cond do
      not Audio.valid?(audio) ->
        {:reply, {:error, :invalid_audio}, state}

      byte_size(audio.data) > state.max_bytes ->
        {:reply, {:error, :chunk_too_large}, state}

      state.rate && state.rate != audio.sample_rate ->
        {:reply, {:error, :sample_rate_changed}, state}

      state.waiting ->
        {:reply, {:error, :producer_busy}, state}

      audio.data == <<>> ->
        {:reply, :ok, state}

      true ->
        audio = %{audio | data: :binary.copy(audio.data)}

        case ensure_pipeline(state, audio.sample_rate) do
          {:ok, state} ->
            if state.bytes + byte_size(audio.data) <= state.max_bytes do
              state = enqueue(state, audio) |> serve()
              {:reply, :ok, state}
            else
              ref = Process.monitor(elem(from, 0))

              notify(
                state,
                key,
                {:backpressure,
                 %{queued_bytes: state.bytes, waiting_bytes: byte_size(audio.data)}}
              )

              {:noreply, %{state | waiting: %{from: from, audio: audio, ref: ref}}}
            end

          {:error, reason, state} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:push, _, _}, _from, state), do: {:reply, {:error, :stale_turn}, state}

  def handle_call({:finish, key}, _from, %{key: key} = state) do
    if state.pipeline == nil and not state.finished?, do: notify(state, key, :drained)
    {:reply, :ok, serve(%{state | finished?: true})}
  end

  def handle_call({:finish, _}, _from, state), do: {:reply, {:error, :stale_turn}, state}

  def handle_call({:flush, key}, _from, %{key: key} = state) do
    started = System.monotonic_time(:microsecond)

    case clear(state) do
      {:ok, state} ->
        us = System.monotonic_time(:microsecond) - started
        notify(state, key, {:flushed, %{control_us: us}})
        {:reply, :ok, %{state | last_flush_us: us}}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:flush, _}, _from, state), do: {:reply, :ok, state}

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       queued_bytes: state.bytes,
       blocked?: state.waiting != nil,
       key: state.key,
       pipeline: state.pipeline && state.pipeline.pid,
       last_flush_us: state.last_flush_us
     }, state}
  end

  @impl true
  def handle_info({:take_pcm, key, source, request}, %{key: key} = state) when key != nil do
    {:noreply, serve(%{state | demand: {source, request}})}
  end

  def handle_info({:take_pcm, _key, source, request}, state) do
    send(source, {:pcm, request, :end_of_stream})
    {:noreply, state}
  end

  def handle_info({:playback_notification, key, child, notification}, %{key: key} = state) do
    notify(state, key, {:sink_notification, child, notification})
    {:noreply, state}
  end

  def handle_info({:playback_drained, key}, %{key: key} = state) do
    {:noreply, %{state | draining?: true}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{session_ref: ref} = state) do
    case clear(state) do
      {:ok, state} -> {:noreply, %{state | session: nil, session_ref: nil}}
      {:error, reason, state} -> {:stop, reason, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{waiting: %{ref: ref}} = state),
    do: {:noreply, %{state | waiting: nil}}

  def handle_info({:DOWN, ref, :process, _, reason}, %{pipeline: %{ref: ref}} = state) do
    event =
      if state.draining? and reason in [:normal, :shutdown], do: :drained, else: {:failed, reason}

    notify(state, state.key, event)

    if state.waiting do
      Process.demonitor(state.waiting.ref, [:flush])
      GenServer.reply(state.waiting.from, {:error, {:pipeline_exit, reason}})
    end

    {:noreply,
     %{state | pipeline: nil, key: nil, queue: :queue.new(), bytes: 0, waiting: nil, demand: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: clear(state)

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
        state = %{state | queue: queue, bytes: state.bytes - byte_size(audio.data), demand: nil}
        release_producer(state)

      {:empty, _} when state.finished? ->
        send(source, {:pcm, request, :end_of_stream})
        %{state | demand: nil}

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

  defp ensure_pipeline(%{pipeline: nil} = state, rate) do
    options = %{playback: self(), key: state.key, rate: rate, sink: state.sink}

    case Membrane.Pipeline.start_link(AudioFlow.PlaybackPipeline, options) do
      {:ok, supervisor, pipeline} ->
        notify(state, state.key, {:pipeline_started, pipeline})

        {:ok,
         %{
           state
           | rate: rate,
             pipeline: %{pid: pipeline, supervisor: supervisor, ref: Process.monitor(supervisor)}
         }}

      {:error, reason} ->
        {:error, {:pipeline_start, reason}, state}
    end
  end

  defp ensure_pipeline(state, _rate), do: {:ok, state}

  defp clear(state) do
    if state.waiting do
      Process.demonitor(state.waiting.ref, [:flush])
      GenServer.reply(state.waiting.from, {:error, :stale_turn})
    end

    case stop_pipeline(state.pipeline) do
      :ok ->
        {:ok,
         %{
           state
           | key: nil,
             pipeline: nil,
             waiting: nil,
             queue: :queue.new(),
             bytes: 0,
             rate: nil,
             demand: nil,
             finished?: false,
             draining?: false,
             first_buffer_us: nil
         }}

      {:error, reason} ->
        {:error, reason, %{state | waiting: nil}}
    end
  end

  defp stop_pipeline(nil), do: :ok

  defp stop_pipeline(pipeline) do
    if Process.alive?(pipeline.supervisor),
      do: Supervisor.stop(pipeline.supervisor, :shutdown, 5000)

    Process.demonitor(pipeline.ref, [:flush])
    :ok
  catch
    :exit, {:noproc, _} -> :ok
    :exit, reason -> {:error, {:pipeline_stop, reason}}
  end

  defp notify(state, key, event), do: send(state.observer, {__MODULE__, self(), key, event})
end
