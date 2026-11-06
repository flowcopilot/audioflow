defmodule AudioFlow.Transcript do
  @moduledoc """
  A complete transcript: the joined text and its timed segments.

  `AudioFlow.Transcription.transcribe/3` returns this struct. `to_srt/1` and
  `to_vtt/1` format segments as captions. Each segment must have start and end
  times for caption output.
  """
  alias AudioFlow.Transcript.Segment

  @enforce_keys [:text, :segments]
  defstruct [:text, :segments]

  @type t :: %__MODULE__{text: String.t(), segments: [Segment.t()]}

  @doc "Build a transcript from ordered segments. Empty segments are dropped."
  def new(segments) do
    segments = Enum.reject(segments, &(&1.text == ""))
    %__MODULE__{text: Enum.map_join(segments, " ", & &1.text), segments: segments}
  end

  @doc "Format timed segments as SubRip (SRT) captions."
  def to_srt(%__MODULE__{segments: segments}) do
    segments
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {segment, index} ->
      "#{index}\n#{time(segment.start_ms, ",")} --> #{time(segment.end_ms, ",")}\n#{segment.text}\n"
    end)
  end

  @doc "Format timed segments as WebVTT captions."
  def to_vtt(%__MODULE__{segments: segments}) do
    cues =
      Enum.map(segments, fn segment ->
        "#{time(segment.start_ms, ".")} --> #{time(segment.end_ms, ".")}\n#{segment.text}\n"
      end)

    Enum.join(["WEBVTT\n" | cues], "\n")
  end

  defp time(ms, separator) when is_integer(ms) and ms >= 0 do
    hours = div(ms, 3_600_000)
    minutes = ms |> div(60_000) |> rem(60)
    seconds = ms |> div(1000) |> rem(60)

    [hours, minutes, seconds]
    |> Enum.map_join(":", &pad(&1, 2))
    |> Kernel.<>(separator <> pad(rem(ms, 1000), 3))
  end

  defp time(_, _), do: raise(ArgumentError, "caption segments require start and end times")

  defp pad(value, width), do: value |> Integer.to_string() |> String.pad_leading(width, "0")
end
