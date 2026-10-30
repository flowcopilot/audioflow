defmodule AudioFlow.VoiceDetector do
  @moduledoc """
  Stateful voice detector contract. A stream owns the returned state.
  Model weights must stay in a shared inference service.
  """
  @callback init(keyword()) :: {pos_integer(), pos_integer(), term()}
  @callback predict(AudioFlow.Audio.t(), term()) :: {number(), term()}
end
