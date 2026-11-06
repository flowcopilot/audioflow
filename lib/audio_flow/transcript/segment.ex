defmodule AudioFlow.Transcript.Segment do
  @moduledoc """
  One final transcript segment. An STT adapter can emit this in place of a
  string to give timing.

  `start_ms` and `end_ms` are offsets from the start of the adapter input, or
  `nil` when the engine gives no timing. `words` is a list of maps with `:word`,
  `:start_ms` and `:end_ms`, and an optional `:confidence`.
  """
  @enforce_keys [:text]
  defstruct [:text, start_ms: nil, end_ms: nil, words: []]

  @type word :: %{
          required(:word) => String.t(),
          required(:start_ms) => non_neg_integer(),
          required(:end_ms) => non_neg_integer(),
          optional(:confidence) => number()
        }
  @type t :: %__MODULE__{
          text: String.t(),
          start_ms: non_neg_integer() | nil,
          end_ms: non_neg_integer() | nil,
          words: [word()]
        }

  def valid?(%__MODULE__{text: text, start_ms: start_ms, end_ms: end_ms, words: words}) do
    is_binary(text) and String.valid?(text) and time?(start_ms) and time?(end_ms) and
      (start_ms == nil or end_ms == nil or start_ms <= end_ms) and is_list(words) and
      Enum.all?(words, &word?/1)
  end

  def valid?(_), do: false

  @doc "Move the segment and its words later by `offset_ms`. Missing times stay missing."
  def shift(%__MODULE__{} = segment, offset_ms) do
    %{
      segment
      | start_ms: add(segment.start_ms, offset_ms),
        end_ms: add(segment.end_ms, offset_ms),
        words:
          Enum.map(
            segment.words,
            &%{&1 | start_ms: &1.start_ms + offset_ms, end_ms: &1.end_ms + offset_ms}
          )
    }
  end

  @doc "Approximate payload size, for session output limits."
  def bytes(%__MODULE__{text: text, words: words}),
    do: byte_size(text) + Enum.reduce(words, 0, &(byte_size(&1.word) + 24 + &2))

  defp add(nil, _), do: nil
  defp add(ms, offset), do: ms + offset

  defp time?(ms), do: ms == nil or (is_integer(ms) and ms >= 0)

  defp word?(%{word: word, start_ms: start_ms, end_ms: end_ms} = map) do
    is_binary(word) and is_integer(start_ms) and is_integer(end_ms) and 0 <= start_ms and
      start_ms <= end_ms and (not Map.has_key?(map, :confidence) or is_number(map.confidence))
  end

  defp word?(_), do: false
end
