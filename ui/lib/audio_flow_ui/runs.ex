defmodule AudioFlowUI.Runs do
  @moduledoc """
  Runs one text turn of a graph and collects its events.

  The calling process owns a new session for the turn and stops it after the
  turn. Audio events report their size, not their PCM.
  """
  alias AudioFlow.{Graph, Text}

  @timeout_ms 120_000

  def run_text(graph, text, timeout_ms \\ @timeout_ms) do
    with :ok <- text_input(graph),
         {:ok, options} <- Graph.session_options(graph, AudioFlowUI.catalog()),
         {:ok, session} <- AudioFlow.start_session(options) do
      try do
        case AudioFlow.submit(session, %Text{data: text}) do
          {:ok, turn} -> collect(session, turn, [], timeout_ms)
          {:error, reason} -> {:error, reason}
        end
      after
        AudioFlow.stop_session(session)
      end
    end
  end

  defp text_input(graph) do
    if Enum.any?(Graph.normalize(graph)["nodes"] || [], &(&1["type"] == "input.text")),
      do: :ok,
      else: {:error, ["the graph has no text input node"]}
  end

  defp collect(session, turn, events, timeout_ms) do
    receive do
      {AudioFlow, ^session, ^turn, {status, metrics}} when status in [:done, :cancelled] ->
        {:ok, result(status, events, metrics)}

      {AudioFlow, ^session, ^turn, {:error, reason, metrics}} ->
        {:ok, Map.put(result(:error, events, metrics), "error", inspect(reason))}

      {AudioFlow, ^session, ^turn, event} ->
        collect(session, turn, [event(event) | events], timeout_ms)
    after
      timeout_ms ->
        AudioFlow.cancel(session)
        {:error, :timeout}
    end
  end

  defp result(status, events, metrics) do
    events = Enum.reverse(events)

    %{
      "status" => Atom.to_string(status),
      "reply" => for(%{"type" => "text", "text" => text} <- events, into: "", do: text),
      "events" => events,
      "metrics" => Map.new(metrics, fn {key, value} -> {Atom.to_string(key), value} end)
    }
  end

  defp event({:audio, audio}),
    do: %{"type" => "audio", "bytes" => byte_size(audio.data), "sample_rate" => audio.sample_rate}

  defp event({type, text}), do: %{"type" => Atom.to_string(type), "text" => text}
end
