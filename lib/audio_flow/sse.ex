defmodule AudioFlow.SSE do
  @moduledoc false
  # Incremental SSE framing. JSON is decoded only after a complete event, so
  # HTTP chunks can split UTF-8 characters, fields, and CRLF line endings.
  def new(limit), do: %{line: "", data: [], bytes: 0, limit: limit, cr?: false, preamble: ""}

  def push(%{preamble: prefix} = state, chunk) when is_binary(prefix) do
    case prefix <> chunk do
      "" -> {:ok, [], state}
      <<239, 187, 191, rest::binary>> -> scan(rest, %{state | preamble: nil}, [])
      <<239>> = prefix -> {:ok, [], %{state | preamble: prefix}}
      <<239, 187>> = prefix -> {:ok, [], %{state | preamble: prefix}}
      data -> scan(data, %{state | preamble: nil}, [])
    end
  end

  def push(state, chunk), do: scan(chunk, state, [])

  defp scan(<<>>, state, events), do: {:ok, Enum.reverse(events), state}

  defp scan(<<10, rest::binary>>, %{cr?: true} = state, events),
    do: scan(rest, %{state | cr?: false}, events)

  defp scan(chunk, state, events) do
    case :binary.match(chunk, ["\r", "\n"]) do
      :nomatch ->
        append(state, chunk, events)

      {offset, 1} ->
        <<part::binary-size(^offset), newline, rest::binary>> = chunk

        with {:ok, _, state} <- append(state, part, []),
             {:ok, event, state} <- line(state) do
          events = if event == nil, do: events, else: [event | events]
          scan(rest, %{state | cr?: newline == 13}, events)
        end
    end
  end

  defp append(state, bytes, events) do
    size = state.bytes + byte_size(bytes)

    if size > state.limit do
      {:error, :event_too_large}
    else
      {:ok, Enum.reverse(events), %{state | line: state.line <> bytes, bytes: size, cr?: false}}
    end
  end

  defp line(%{line: "", data: data} = state) do
    event = if data == [], do: nil, else: data |> Enum.reverse() |> Enum.join("\n")
    {:ok, event, %{state | line: "", data: [], bytes: 0}}
  end

  defp line(%{bytes: bytes, limit: limit}) when bytes >= limit,
    do: {:error, :event_too_large}

  defp line(%{line: "data:" <> value} = state) do
    value =
      case value do
        " " <> rest -> rest
        other -> other
      end

    {:ok, nil, %{state | line: "", data: [value | state.data], bytes: state.bytes + 1}}
  end

  defp line(state), do: {:ok, nil, %{state | line: "", bytes: state.bytes + 1}}
end
