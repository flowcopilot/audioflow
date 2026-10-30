defmodule AudioFlow.Benchmark do
  @moduledoc """
  Measure turns at fixed concurrency. Every attempt produces a result row.

  Options: `:warmup` (0) and `:timeout_ms` (session timeout plus 5 seconds).
  Warmup rows are retained with `phase: :warmup`. Measured rows use
  `phase: :measured`. Session failure, cancellation, and runner timeout are
  error rows. Normal row timings come from the session, in microseconds.
  """
  @metric_keys [:duration_us, :first_transcript_us, :first_text_us, :first_audio_us]

  def run(options, audio, runs, concurrency, benchmark_options \\ []) do
    warmup = Keyword.get(benchmark_options, :warmup, 0)

    timeout =
      Keyword.get(
        benchmark_options,
        :timeout_ms,
        Keyword.get(options, :timeout_ms, 30_000) + 5000
      )

    unless is_integer(runs) and runs > 0 and is_integer(concurrency) and concurrency > 0 and
             is_integer(warmup) and warmup >= 0 and is_integer(timeout) and timeout > 0,
           do:
             raise(
               ArgumentError,
               "runs, concurrency, and timeout must be positive; warmup must be non-negative"
             )

    phase(options, audio, warmup, concurrency, timeout, :warmup) ++
      phase(options, audio, runs, concurrency, timeout, :measured)
  end

  defp phase(_options, _audio, 0, _concurrency, _timeout, _phase), do: []

  defp phase(options, audio, count, concurrency, timeout, phase) do
    1..count
    |> Task.async_stream(fn index -> measure(index, options, audio, timeout) end,
      max_concurrency: concurrency,
      timeout: timeout + 15_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.with_index(1)
    |> Enum.map(fn {result, index} ->
      row =
        case result do
          {:ok, row} -> row
          {:exit, reason} -> error_row(index, {:runner_exit, reason}, nil)
        end

      Map.merge(row, %{phase: phase, concurrency: concurrency})
    end)
  end

  defp measure(index, options, audio, timeout) do
    started = System.monotonic_time(:microsecond)

    case AudioFlow.start_session(Keyword.put(options, :owner, self())) do
      {:ok, session} ->
        monitor = Process.monitor(session)

        try do
          case AudioFlow.submit(session, audio) do
            {:ok, turn} -> await(index, session, turn, monitor, started, started + timeout * 1000)
            {:error, reason} -> error_row(index, {:submit, reason}, elapsed(started))
          end
        after
          Process.demonitor(monitor, [:flush])
          AudioFlow.stop_session(session)
        end

      {:error, reason} ->
        error_row(index, {:session_start, reason}, elapsed(started))
    end
  rescue
    error -> error_row(index, {:benchmark_exception, Exception.message(error)}, nil)
  catch
    :exit, reason -> error_row(index, {:benchmark_exit, reason}, nil)
  end

  defp await(index, session, turn, monitor, started, deadline) do
    remaining = max(0, div(deadline - System.monotonic_time(:microsecond), 1000))

    receive do
      {AudioFlow, ^session, ^turn, {:done, metrics}} ->
        status = if is_integer(metrics.first_audio_us), do: :ok, else: {:error, :no_audio}
        Map.merge(metrics, %{run: index, status: status})

      {AudioFlow, ^session, ^turn, {:error, reason, metrics}} ->
        Map.merge(metrics, %{run: index, status: {:error, reason}})

      {AudioFlow, ^session, ^turn, {:cancelled, metrics}} ->
        Map.merge(metrics, %{run: index, status: {:error, :cancelled}})

      {:DOWN, ^monitor, :process, ^session, reason} ->
        error_row(index, {:session_exit, reason}, elapsed(started))

      {AudioFlow, ^session, ^turn, _} ->
        await(index, session, turn, monitor, started, deadline)
    after
      remaining -> error_row(index, :benchmark_timeout, elapsed(started))
    end
  end

  defp elapsed(started), do: System.monotonic_time(:microsecond) - started

  defp error_row(index, reason, elapsed) do
    @metric_keys
    |> Map.new(&{&1, nil})
    |> Map.merge(%{run: index, status: {:error, reason}, duration_us: elapsed})
  end
end
