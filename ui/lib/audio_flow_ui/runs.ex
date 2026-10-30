defmodule AudioFlowUI.Runs do
  @moduledoc """
  Runs one text turn of a graph and collects its events.

  The calling process owns a new session for the turn and stops it after the
  turn. Each event names its node. Audio, image, and vector events report
  their size, not their data. The reply is the text of the last text nodes:
  those whose text does not go on to another text node.
  """
  alias AudioFlow.{Graph, Text}

  @timeout_ms 120_000

  def run_text(graph, text, timeout_ms \\ @timeout_ms) do
    with :ok <- text_input(graph),
         {:ok, options} <- Graph.session_options(graph, AudioFlowUI.catalog()),
         {:ok, session} <- AudioFlow.start_session(options) do
      try do
        case AudioFlow.submit(session, %Text{data: text}) do
          {:ok, turn} -> collect(session, turn, graph, [], timeout_ms)
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

  defp collect(session, turn, graph, events, timeout_ms) do
    receive do
      {AudioFlow, ^session, ^turn, {status, metrics}} when status in [:done, :cancelled] ->
        {:ok, result(status, events, metrics, graph)}

      {AudioFlow, ^session, ^turn, {:error, reason, metrics}} ->
        {:ok, Map.put(result(:error, events, metrics, graph), "error", inspect(reason))}

      {AudioFlow, ^session, ^turn, event} ->
        collect(session, turn, graph, [event(event) | events], timeout_ms)
    after
      timeout_ms ->
        AudioFlow.cancel(session)
        {:error, :timeout}
    end
  end

  defp result(status, events, metrics, graph) do
    events = Enum.reverse(events)
    reply_nodes = reply_nodes(graph)

    %{
      "status" => Atom.to_string(status),
      "reply" =>
        for(
          %{"type" => "text", "text" => text, "node" => node} <- events,
          node in reply_nodes,
          into: "",
          do: text
        ),
      "events" => events,
      "metrics" => Map.new(metrics, fn {key, value} -> {Atom.to_string(key), value} end)
    }
  end

  # Nodes with text events, except those whose text goes on to another text node.
  defp reply_nodes(graph) do
    graph = Graph.normalize(graph)
    types = Map.new(AudioFlowUI.node_types(), &{&1["type"], &1})
    events = Map.new(graph["nodes"] || [], &{&1["id"], types[&1["type"]]["event"]})
    targets = Enum.group_by(graph["edges"] || [], & &1["from"], & &1["to"])

    for {id, "text"} <- events,
        not Enum.any?(Map.get(targets, id, []), &(events[&1] == "text")),
        do: id
  end

  defp event({kind, value, node}),
    do: Map.merge(%{"node" => node, "type" => Atom.to_string(kind)}, value(kind, value))

  defp value(:audio, audio),
    do: %{"bytes" => byte_size(audio.data), "sample_rate" => audio.sample_rate}

  defp value(:image, image), do: %{"width" => image.width, "height" => image.height}
  defp value(:vector, vector), do: %{"dimensions" => length(vector)}
  defp value(_, text), do: %{"text" => text}
end
