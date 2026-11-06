defmodule AudioFlow.Graph.Nodes.Audio do
  @moduledoc "Audio conversion nodes."
  @behaviour AudioFlow.Graph.Node

  @rates [8_000, 16_000, 22_050, 24_000, 44_100, 48_000]

  @impl true
  def nodes do
    [
      %{
        type: "audio.resample",
        title: "Resample",
        description: "Converts the complete PCM input to another sample rate.",
        input: :audio,
        output: :audio,
        options: [
          %{
            name: :sample_rate,
            type: {:enum, @rates},
            default: 16_000,
            description: "Output sample rate in Hz. Whisper needs 16000."
          }
        ]
      }
    ]
  end

  @impl true
  def adapter("audio.resample", %{sample_rate: rate}),
    do: {AudioFlow.Adapters.Function, [run: fn audio, emit -> emit.(resample(audio, rate)) end]}

  @doc "Linear interpolation of mono signed 16-bit PCM."
  defdelegate resample(audio, rate), to: AudioFlow.Resampler, as: :linear
end
