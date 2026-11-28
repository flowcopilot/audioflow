defmodule AudioFlow.Test.GatedTurn do
  @moduledoc false
  # A semantic turn detector that answers when the test says so. Each check sends
  # `{:turn_gate, pid, audio}` to `:owner` and waits for `:release` sent to `pid`.
  def init(options), do: options

  def predict(audio, options) do
    send(options[:owner], {:turn_gate, self(), audio})

    receive do
      :release -> Keyword.get(options, :probability, 0.9)
    after
      10_000 -> 0.0
    end
  end
end

defmodule AudioFlow.Test.AmplitudeDetector do
  @moduledoc false
  # Speech when a 20 ms frame (320 samples at 16 kHz) holds a loud sample.
  @behaviour AudioFlow.VoiceDetector
  def init(_options), do: {320, 16_000, nil}

  def predict(%AudioFlow.Audio{data: data}, state) do
    loud = Enum.max(for(<<x::little-signed-16 <- data>>, do: abs(x)))
    {if(loud > 1000, do: 1.0, else: 0.0), state}
  end
end
