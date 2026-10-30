defmodule AudioFlow.Test.FrameDetector do
  @moduledoc false
  @behaviour AudioFlow.VoiceDetector

  def init(_options), do: {512, 16_000, nil}

  def predict(%AudioFlow.Audio{data: <<first::little-signed-16, _::binary-size(1022)>>}, state) do
    probability =
      case first do
        0 -> 0.1
        16000 -> 0.4
        32000 -> 0.9
      end

    {probability, state}
  end
end
