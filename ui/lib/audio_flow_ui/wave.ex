defmodule AudioFlowUI.Wave do
  @moduledoc "Browser playback of bounded, already received PCM; no resampling or mixing."
  def outputs(events) do
    events
    |> Enum.filter(&Map.has_key?(&1, "_pcm"))
    |> Enum.group_by(&{&1["node"], &1["sample_rate"]})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {{node, rate}, chunks} ->
      pcm = Enum.map_join(chunks, & &1["_pcm"])
      size = byte_size(pcm)

      wave =
        <<"RIFF", size + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
          rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data",
          size::little-32, pcm::binary>>

      %{"node" => node, "url" => "data:audio/wav;base64," <> Base.encode64(wave)}
    end)
  end
end
