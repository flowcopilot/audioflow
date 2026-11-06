defmodule AudioFlowUI.Wave do
  @moduledoc "Browser playback of bounded, already received PCM; no resampling or mixing."
  def outputs(events) do
    events
    |> Enum.filter(&Map.has_key?(&1, "_pcm"))
    |> Enum.group_by(&{&1["node"], &1["sample_rate"]})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {{node, rate}, chunks} ->
      pcm = Enum.map_join(chunks, & &1["_pcm"])
      wave = AudioFlow.Wav.encode(%AudioFlow.Audio{data: pcm, sample_rate: rate})

      %{"node" => node, "url" => "data:audio/wav;base64," <> Base.encode64(wave)}
    end)
  end
end
