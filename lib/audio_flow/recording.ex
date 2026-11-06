defmodule AudioFlow.Recording do
  @moduledoc """
  Optional bounded owner-side recorder for genuine AudioFlow session events.

  Keep the returned state in the session owner and call `consume/2` for each
  `{AudioFlow, session, turn, event}` message, in mailbox order. Calls are
  synchronous and apply disk backpressure to that owner. No runtime hooks are
  required. Only one turn is buffered. Text is redacted as a complete stream
  per `{kind, node}` before persistence, so chunk boundaries cannot bypass a
  rule. Ordered event descriptors reference those streams. PCM output is opt-in
  and is never redacted. Images, vectors, error details and metrics are omitted.
  """
  alias AudioFlow.Audio
  alias AudioFlow.Privacy
  alias AudioFlow.Recording.Store

  @enforce_keys [:session, :store, :redactor]
  defstruct [
    :session,
    :store,
    :redactor,
    :turn,
    :last_turn,
    :failed,
    audio: false,
    max_events: 1024,
    max_bytes: 4_000_000,
    bytes: 0,
    count: 0,
    events: []
  ]

  @doc "An explicit redactor is required. Use `&{:ok, &1}` only for intentional plaintext storage."
  def new(session, %Store{} = store, options) when is_pid(session) do
    recorder = struct!(__MODULE__, Keyword.merge(options, session: session, store: store))
    unless is_function(recorder.redactor, 1), do: raise(ArgumentError, "redactor is required")
    unless is_boolean(recorder.audio), do: raise(ArgumentError, "audio must be boolean")

    for key <- [:max_bytes, :max_events] do
      unless is_integer(Map.fetch!(recorder, key)) and Map.fetch!(recorder, key) > 0,
        do: raise(ArgumentError, "#{key} must be positive")
    end

    recorder
  end

  @doc "Returns `{:ok, state, artifact_id_or_nil}` or `{:error, reason, state}`. Always retain state."
  def consume(%{session: session} = recorder, {AudioFlow, session, turn, event})
      when is_reference(turn) do
    cond do
      turn == recorder.last_turn -> {:ok, recorder, nil}
      recorder.turn != nil and recorder.turn != turn -> {:error, :turn_in_progress, recorder}
      true -> consume_event(%{recorder | turn: turn}, event)
    end
  end

  def consume(recorder, _), do: {:ok, recorder, nil}

  @doc "Discard buffered data on owner/session shutdown; no unfinished artifact is written."
  def discard(recorder), do: reset(recorder)

  defp consume_event(recorder, {status, _}) when status in [:done, :cancelled],
    do: finish(recorder, status)

  defp consume_event(recorder, {:error, _, _}), do: finish(recorder, :error)

  defp consume_event(%{failed: reason} = recorder, _) when reason != nil,
    do: {:error, reason, recorder}

  defp consume_event(recorder, {kind, value}), do: append(recorder, kind, value, nil)
  defp consume_event(recorder, {kind, value, node}), do: append(recorder, kind, value, node)
  defp consume_event(recorder, _), do: {:ok, recorder, nil}

  defp append(recorder, kind, value, node) do
    case recorded_event(recorder, kind, value, node) do
      nil -> {:ok, recorder, nil}
      event -> store_event(recorder, event)
    end
  end

  defp recorded_event(_recorder, kind, value, node)
       when kind in [:text, :transcript, :description] and is_binary(value),
       do: %{kind: Atom.to_string(kind), node: node_id(node), text: value}

  defp recorded_event(recorder, :segment, %AudioFlow.Transcript.Segment{text: text}, node),
    do: recorded_event(recorder, :transcript, text, node)

  defp recorded_event(recorder, :audio, value, node) do
    if recorder.audio and Audio.valid?(value) do
      %{
        kind: "audio",
        node: node_id(node),
        pcm_s16le: Base.encode64(value.data),
        sample_rate: value.sample_rate
      }
    end
  end

  defp recorded_event(_recorder, _kind, _value, _node), do: nil

  defp store_event(recorder, event) do
    cond do
      recorder.count >= recorder.max_events ->
        fail(recorder, :event_limit)

      recorder.bytes + event_bytes(event) > recorder.max_bytes ->
        fail(recorder, :byte_limit)

      true ->
        {:ok,
         %{
           recorder
           | events: [event | recorder.events],
             count: recorder.count + 1,
             bytes: recorder.bytes + event_bytes(event)
         }, nil}
    end
  end

  defp finish(%{failed: reason} = recorder, _) when reason != nil,
    do: {:error, reason, reset(recorder)}

  defp finish(recorder, status) do
    events = Enum.reverse(recorder.events)

    grouped =
      Enum.filter(events, &Map.has_key?(&1, :text))
      |> Enum.group_by(&{&1.kind, &1.node}, & &1.text)

    result =
      Enum.reduce_while(grouped, {:ok, []}, fn {{kind, node}, chunks}, {:ok, streams} ->
        case Privacy.redact(recorder.redactor, Enum.join(chunks)) do
          {:ok, text} -> {:cont, {:ok, [%{kind: kind, node: node, text: text} | streams]}}
          error -> {:halt, error}
        end
      end)

    result =
      with {:ok, streams} <- result do
        Store.write(recorder.store, %{
          version: 1,
          status: Atom.to_string(status),
          streams: Enum.sort_by(streams, &{&1.kind, &1.node}),
          events:
            Enum.with_index(events, fn event, index ->
              event |> Map.delete(:text) |> Map.put(:sequence, index)
            end)
        })
      end

    case result do
      {:ok, id} -> {:ok, reset(recorder), id}
      {:error, reason} -> {:error, reason, reset(recorder)}
    end
  end

  defp event_bytes(%{text: text, node: node}),
    do: byte_size(text) + byte_size(node || "") + 64

  defp event_bytes(%{pcm_s16le: pcm, node: node}),
    do: byte_size(pcm) + byte_size(node || "") + 128

  defp fail(recorder, reason),
    do: {:error, reason, %{recorder | failed: reason, events: [], bytes: 0}}

  defp reset(recorder),
    do: %{
      recorder
      | turn: nil,
        last_turn: recorder.turn || recorder.last_turn,
        events: [],
        bytes: 0,
        count: 0,
        failed: nil
    }

  defp node_id(nil), do: nil
  defp node_id(node) when is_atom(node), do: Atom.to_string(node)
  defp node_id(node) when is_binary(node), do: if(String.valid?(node), do: node, else: nil)
  defp node_id(_), do: nil
end
