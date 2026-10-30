defmodule AudioFlow.Worker do
  @moduledoc """
  Bounded inference worker for local or connected Erlang nodes.

  Start once with `:adapter`, an engine-neutral adapter tuple, and optional
  `:name`, `:max_concurrency` (1), and `:timeout_ms` (30,000). Model weights
  remain in the adapter's shared serving. The AudioFlow application must run on
  the worker node. Requests above capacity are rejected without a waiting queue.

  Use as an adapter with `:worker` (PID, registered name, or `{name, node}`) and
  optional `:timeout_ms` (30,000). Outputs are acknowledged one at a time in the
  calling process. Caller exit, cancellation, and worker deadlines stop the
  inference task. A shared hardware batch can still run to completion.

  Erlang distribution must connect trusted nodes with compatible code. This
  worker sends input and output terms; it does not transfer model weights.
  Remote targets must already be connected. Reconnect nodes before routing to them.
  A request error after admission is terminal and must not be retried blindly.
  """
  use GenServer
  @behaviour AudioFlow.Adapter

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @impl AudioFlow.Adapter
  def run(input, options, emit) do
    worker = Keyword.fetch!(options, :worker)
    timeout = positive!(options, :timeout_ms, 30_000)
    request = make_ref()
    reply_to = :erlang.alias()
    deadline = now() + timeout

    try do
      case admit(worker, request, reply_to, input, timeout) do
        {:ok, pid} ->
          monitor = Process.monitor(pid)

          try do
            consume(request, monitor, deadline, emit)
          after
            cancel(pid, request)
            Process.demonitor(monitor, [:flush])
          end

        {:error, {:worker_admission_failed, _}} = error ->
          GenServer.cast(worker, {:cancel, request, self()})
          error

        error ->
          error
      end
    after
      :erlang.unalias(reply_to)
      discard(request)
    end
  end

  @impl GenServer
  def init(options) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       adapter: Keyword.fetch!(options, :adapter),
       limit: positive!(options, :max_concurrency, 1),
       timeout: positive!(options, :timeout_ms, 30_000),
       jobs: %{}
     }}
  end

  @impl GenServer
  def handle_call({:cancel, request}, {caller, _}, state) do
    {:reply, :ok, cancel_job(state, request, caller)}
  end

  def handle_call({:run, request, reply_to, input}, {caller, _}, state) do
    if map_size(state.jobs) >= state.limit do
      {:reply, {:error, {:worker_rejected, :busy}}, state}
    else
      adapter = state.adapter

      task =
        Task.Supervisor.async(AudioFlow.Tasks, fn ->
          execute(adapter, input, fn value ->
            send(reply_to, {__MODULE__, request, {:output, self(), value}})

            receive do
              {^request, :ack} -> :ok
            end
          end)
        end)

      job = %{
        task: task,
        caller: caller,
        caller_ref: Process.monitor(caller),
        request: request,
        reply_to: reply_to,
        timer: Process.send_after(self(), {:timeout, task.ref}, state.timeout)
      }

      {:reply, {:ok, self()}, %{state | jobs: Map.put(state.jobs, task.ref, job)}}
    end
  end

  @impl GenServer
  def handle_cast({:cancel, request, caller}, state),
    do: {:noreply, cancel_job(state, request, caller)}

  @impl GenServer
  def handle_info({ref, result}, state) when is_map_key(state.jobs, ref) do
    job = state.jobs[ref]
    state = release(state, ref, job)
    send(job.reply_to, {__MODULE__, job.request, {:done, result}})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    cond do
      job = state.jobs[ref] ->
        state = release(state, ref, job)
        send(job.reply_to, {__MODULE__, job.request, {:done, {:error, {:task_exit, reason}}}})
        {:noreply, state}

      entry = Enum.find(state.jobs, fn {_, job} -> job.caller_ref == ref end) ->
        {task_ref, job} = entry
        {:noreply, stop_job(state, task_ref, job)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:timeout, ref}, state) when is_map_key(state.jobs, ref) do
    job = state.jobs[ref]
    state = stop_job(state, ref, job)
    send(job.reply_to, {__MODULE__, job.request, {:done, {:error, :worker_timeout}}})
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_, state) do
    Enum.each(state.jobs, fn {ref, job} -> stop_job(state, ref, job) end)
  end

  defp admit(worker, request, reply_to, input, timeout) do
    target_node = target_node(worker)

    if target_node != node() and target_node not in Node.list(:connected) do
      {:error, {:worker_unavailable, {:nodedown, target_node}}}
    else
      GenServer.call(worker, {:run, request, reply_to, input}, timeout)
    end
  catch
    :exit, {:noproc, _} -> {:error, {:worker_unavailable, :noproc}}
    :exit, reason -> {:error, {:worker_admission_failed, reason}}
  end

  defp target_node(pid) when is_pid(pid), do: node(pid)

  defp target_node({name, target_node}) when is_atom(name) and is_atom(target_node),
    do: target_node

  defp target_node(_), do: node()

  defp cancel(worker, request) do
    GenServer.call(worker, {:cancel, request}, 1_000)
  catch
    :exit, _ -> GenServer.cast(worker, {:cancel, request, self()})
  end

  defp consume(request, monitor, deadline, emit) do
    remaining = deadline - now()

    if remaining <= 0 do
      {:error, :worker_timeout}
    else
      receive_output(request, monitor, deadline, remaining, emit)
    end
  end

  defp receive_output(request, monitor, deadline, remaining, emit) do
    receive do
      {__MODULE__, ^request, {:output, producer, value}} ->
        :ok = emit.(value)
        send(producer, {request, :ack})
        consume(request, monitor, deadline, emit)

      {__MODULE__, ^request, {:done, result}} ->
        result

      {:DOWN, ^monitor, :process, _, reason} ->
        {:error, {:worker_exit, reason}}
    after
      remaining -> {:error, :worker_timeout}
    end
  end

  defp execute(adapter, input, emit) do
    AudioFlow.Adapter.run(adapter, input, emit)
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    :throw, reason -> {:error, reason}
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp stop_job(state, ref, job) do
    Task.shutdown(job.task, :brutal_kill)
    release(state, ref, job)
  end

  defp cancel_job(state, request, caller) do
    case Enum.find(state.jobs, fn {_, job} ->
           job.request == request and job.caller == caller
         end) do
      nil -> state
      {ref, job} -> stop_job(state, ref, job)
    end
  end

  defp release(state, ref, job) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.caller_ref, [:flush])
    Process.demonitor(ref, [:flush])
    Process.unlink(job.task.pid)
    %{state | jobs: Map.delete(state.jobs, ref)}
  end

  defp discard(request) do
    receive do
      {__MODULE__, ^request, _} -> discard(request)
    after
      0 -> :ok
    end
  end

  defp positive!(options, key, default) do
    value = Keyword.get(options, key, default)
    if not (is_integer(value) and value > 0), do: raise(ArgumentError, "#{key} must be positive")
    value
  end

  defp now, do: System.monotonic_time(:millisecond)
end
