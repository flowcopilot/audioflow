defmodule AudioFlow.Phonemizer do
  @moduledoc "Text-to-phoneme contract for speech engines."
  @callback phonemize(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
end
