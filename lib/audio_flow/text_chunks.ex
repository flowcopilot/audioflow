defmodule AudioFlow.TextChunks do
  @moduledoc "Sentence-sized text chunks for speech synthesis, with all input text preserved."

  @doc """
  Group a text stream at sentence punctuation followed by whitespace.
  Common English titles, abbreviations, and initials stay with the next word.
  A final fragment is emitted when the stream ends. This is a bounded-model
  streaming helper, not a general linguistic sentence parser.
  """
  def sentences(stream) do
    Stream.transform(
      stream,
      fn -> "" end,
      fn chunk, pending -> split(pending <> chunk) end,
      fn pending -> {if(pending == "", do: [], else: [pending]), ""} end,
      fn _ -> :ok end
    )
  end

  defp split(text) do
    {sentences, start} =
      Regex.scan(~r/[.!?]["'”’)\]]*\s+/u, text, return: :index)
      |> Enum.reduce({[], 0}, fn [{offset, length}], {sentences, start} ->
        ending = offset + length
        candidate = binary_part(text, start, ending - start)
        tail = candidate |> String.trim_trailing() |> String.replace(~r/["'”’)\]]+$/u, "")

        if Regex.match?(
             ~r/(?:\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|No|vs|etc)|\b[A-Za-z]|\b(?:e\.g|i\.e))\.$/iu,
             tail
           ) do
          {sentences, start}
        else
          {[candidate | sentences], ending}
        end
      end)

    {Enum.reverse(sentences), binary_part(text, start, byte_size(text) - start)}
  end
end
