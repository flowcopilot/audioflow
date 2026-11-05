defmodule AudioFlow.History do
  @moduledoc false

  @options_schema [
    max_turns: [type: :pos_integer, default: 8],
    max_bytes: [type: :pos_integer, default: 16_384]
  ]

  def new(false), do: nil
  def new(nil), do: nil
  def new(true), do: new([])

  def new(options) when is_list(options) do
    options =
      AudioFlow.RuntimeOptions.validate!(options, @options_schema,
        max_turns: "history max_turns must be positive",
        max_bytes: "history max_bytes must be positive"
      )

    %{turns: [], max_turns: options[:max_turns], max_bytes: options[:max_bytes]}
  end

  def prompt(history, user) do
    if byte_size(user) > history.max_bytes do
      {:error, :context_limit}
    else
      turns = retain(history.turns, history.max_turns, history.max_bytes - byte_size(user))

      messages =
        Enum.flat_map(turns, fn {user, assistant} ->
          [%{role: :user, content: user}, %{role: :assistant, content: assistant}]
        end) ++ [%{role: :user, content: user}]

      {:ok, messages, %{history: history, user: user, reply: [], reply_bytes: 0}}
    end
  end

  def append(nil, _text), do: {:error, :context_not_ready}

  def append(context, text) do
    bytes = context.reply_bytes + byte_size(text)

    if byte_size(context.user) + bytes > context.history.max_bytes do
      {:error, :context_limit}
    else
      {:ok, %{context | reply: [text | context.reply], reply_bytes: bytes}}
    end
  end

  def commit(context) do
    reply = context.reply |> Enum.reverse() |> IO.iodata_to_binary()
    history = context.history

    if String.trim(reply) == "" do
      history
    else
      turns =
        retain(history.turns ++ [{context.user, reply}], history.max_turns, history.max_bytes)

      %{history | turns: turns}
    end
  end

  def commit_heard(nil, _bytes), do: nil

  def commit_heard(context, bytes) do
    reply = context.reply |> Enum.reverse() |> IO.iodata_to_binary()
    reply = binary_part(reply, 0, min(bytes, byte_size(reply)))
    commit(%{context | reply: [reply], reply_bytes: byte_size(reply)})
  end

  def clear(nil), do: nil
  def clear(history), do: %{history | turns: []}

  defp retain([], _max_turns, _max_bytes), do: []

  defp retain([_ | rest] = turns, max_turns, max_bytes) do
    bytes =
      Enum.reduce(turns, 0, fn {user, assistant}, sum ->
        sum + byte_size(user) + byte_size(assistant)
      end)

    if length(turns) > max_turns or bytes > max_bytes,
      do: retain(rest, max_turns, max_bytes),
      else: turns
  end
end
