defmodule AudioFlow.Test.AlwaysSpeechDetector do
  @moduledoc false
  @behaviour AudioFlow.VoiceDetector
  def init(_), do: {512, 16000, nil}
  def predict(_audio, state), do: {0.9, state}
end
