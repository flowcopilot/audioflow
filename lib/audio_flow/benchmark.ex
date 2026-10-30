defmodule AudioFlow.Benchmark do
  @moduledoc "Run real or synthetic turns at a fixed concurrency. Results use microseconds."

  def run(options, audio, runs, concurrency) when runs > 0 and concurrency > 0 do
    1..runs
    |> Task.async_stream(fn index -> measure(index, options, audio) end,
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp measure(index, options, audio) do
    {:ok, session} = AudioFlow.start_session(Keyword.put(options, :owner, self()))

    try do
      {:ok, turn} = AudioFlow.submit(session, audio)
      await(index, session, turn)
    after
      AudioFlow.stop_session(session)
    end
  end

  defp await(index, session, turn) do
    receive do
      {AudioFlow, ^session, ^turn, {:done, metrics}} ->
        Map.merge(metrics, %{run: index, status: :ok})

      {AudioFlow, ^session, ^turn, {:error, reason, metrics}} ->
        Map.merge(metrics, %{run: index, status: {:error, reason}})

      {AudioFlow, ^session, ^turn, _} ->
        await(index, session, turn)
    end
  end
end
