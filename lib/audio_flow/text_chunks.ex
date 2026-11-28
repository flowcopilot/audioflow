defmodule AudioFlow.TextChunks do
  @moduledoc "Sentence-sized text chunks for speech synthesis, with all input text preserved."

  # Bytes of the old buffer that `push/3` scans again. A boundary needs at most a
  # terminator, a few closing quotes and the whitespace that follows, and the
  # previous call could not see the end of that run.
  @lookback 16
  # Bytes before the terminator that the abbreviation check reads.
  @tail 24
  @default_max_bytes 240

  @doc """
  Group a text stream at sentence boundaries. A boundary is `.`, `!` or `?`
  (with closing quotes or brackets) followed by whitespace, or a CJK terminator
  (`。`, `！`, `？`, `｡`) that needs no whitespace. Common English titles,
  abbreviations, and initials stay with the next word. A final fragment is
  emitted when the stream ends. This is a bounded-model streaming helper, not a
  general linguistic sentence parser.

  A buffer that grows past `:max_bytes` without a boundary is split anyway, see
  `push/3`.
  """
  def sentences(stream, options \\ []) do
    Stream.transform(
      stream,
      fn -> "" end,
      fn chunk, pending -> push(pending, chunk, options) end,
      fn pending -> {if(pending == "", do: [], else: [pending]), ""} end,
      fn _ -> :ok end
    )
  end

  @doc """
  Append text to an incremental buffer, returning complete sentences and the new buffer.

  Each call scans only the new text and a few bytes before it, so the cost of a
  stream is linear in its length. Pass the returned buffer to the next call.

  A buffer longer than `:max_bytes` (default #{@default_max_bytes}) without a
  sentence boundary is split at the last clause mark (`,` `;` `:` `、` `，`), or
  at the last whitespace, or else at a character boundary. Text with no
  punctuation, for example a list or a language without terminators, then still
  reaches speech synthesis in bounded pieces. All text is preserved.
  """
  def push(pending, chunk, options \\ []) when is_binary(pending) and is_binary(chunk) do
    limit = Keyword.get(options, :max_bytes, @default_max_bytes)
    from = boundary(pending, max(byte_size(pending) - @lookback, 0))
    text = pending <> chunk

    {sentences, start} =
      text
      |> boundaries(from)
      |> Enum.reduce({[], 0}, fn match, {sentences, start} ->
        ending = ending(match)

        if abbreviation?(text, match, start) do
          {sentences, start}
        else
          {[binary_part(text, start, ending - start) | sentences], ending}
        end
      end)

    rest = binary_part(text, start, byte_size(text) - start)
    {pieces, rest} = split_long(rest, limit, [])
    {Enum.reverse(sentences, pieces), rest}
  end

  # Offsets of every boundary at or after `from`: `{offset, length}` for a CJK
  # terminator, and `{offset, length, terminator_end}` for an ASCII one.
  defp boundaries(text, from) do
    pattern = ~r/([.!?]["'”’)\]]*)\s+|[。！？｡]+[」』）"'”’)\]]*/u

    case :re.run(text, Regex.re_pattern(pattern), [
           :global,
           {:offset, from},
           {:capture, :all, :index}
         ]) do
      {:match, matches} -> Enum.map(matches, &boundary_match/1)
      :nomatch -> []
    end
  end

  defp boundary_match([{offset, length}]), do: {offset, length}
  defp boundary_match([{offset, length}, {group, size}]), do: {offset, length, group + size}

  defp ending({offset, length}), do: offset + length
  defp ending({offset, length, _terminator}), do: offset + length

  defp abbreviation?(_text, {_, _}, _start), do: false

  defp abbreviation?(text, {offset, _length, terminator}, start) do
    from = max(boundary(text, max(offset - @tail, 0)), start)

    tail =
      text
      |> binary_part(from, terminator - from)
      |> String.replace(~r/["'”’)\]]+$/u, "")

    Regex.match?(
      ~r/(?:\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|No|vs|etc)|\b[A-Za-z]|\b(?:e\.g|i\.e))\.$/iu,
      tail
    )
  end

  defp split_long(text, max, pieces) when byte_size(text) <= max, do: {Enum.reverse(pieces), text}

  defp split_long(text, max, pieces) do
    cut = cut(text, max)

    split_long(binary_part(text, cut, byte_size(text) - cut), max, [
      binary_part(text, 0, cut) | pieces
    ])
  end

  # The end of the last clause mark or whitespace run inside the first `max`
  # bytes, or a character boundary at `max`.
  defp cut(text, max) do
    limit = boundary(text, max)
    window = binary_part(text, 0, limit)

    case :re.run(window, Regex.re_pattern(~r/(?:[,;:]\s*|[，、；：]|\s+)/u), [
           :global,
           {:capture, :first, :index}
         ]) do
      {:match, matches} ->
        {offset, length} = matches |> List.last() |> hd()
        if offset + length > 0, do: offset + length, else: limit

      :nomatch ->
        limit
    end
  end

  # The nearest UTF-8 character start at or before `position`.
  defp boundary(_text, 0), do: 0

  defp boundary(text, position) when position >= byte_size(text), do: byte_size(text)

  defp boundary(text, position) do
    if Bitwise.band(:binary.at(text, position), 0xC0) == 0x80,
      do: boundary(text, position - 1),
      else: position
  end
end
