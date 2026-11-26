defmodule AudioFlowReleases.Opus do
  @moduledoc false
  alias Membrane.Opus.Decoder.Native, as: Decoder
  alias Membrane.Opus.Encoder.Native, as: Encoder

  @doc "20 ms Opus frames at 48 kHz: `loud` frames of a tone, then `quiet` silent ones."
  def frames(loud, quiet) do
    encoder = Encoder.create(48_000, 1, 2048, -1000, 3001)

    tone =
      for i <- 0..959,
          into: <<>>,
          do: <<round(:math.sin(i / 960 * 2 * :math.pi() * 20) * 12_000)::little-signed-16>>

    for pcm <- List.duplicate(tone, loud) ++ List.duplicate(<<0::size(960 * 16)>>, quiet) do
      {:ok, packet} = Encoder.encode_packet(encoder, pcm, 960)
      packet
    end
  end

  def decode(payload), do: Decoder.decode_packet(Decoder.create(48_000, 1), payload)
end

defmodule AudioFlowReleases.AmplitudeDetector do
  @moduledoc false
  def init(_), do: {320, 16_000, nil}

  def predict(%AudioFlow.Audio{data: data}, state) do
    speech = for(<<x::little-signed-16 <- data>>, do: abs(x)) |> Enum.max()
    {if(speech > 1000, do: 1.0, else: 0.0), state}
  end
end
