defmodule AudioFlow.Audio do
  @moduledoc "Mono signed 16-bit little-endian PCM audio."
  @enforce_keys [:data, :sample_rate]
  defstruct [:data, :sample_rate]

  @type t :: %__MODULE__{data: binary(), sample_rate: pos_integer()}

  def valid?(%__MODULE__{data: data, sample_rate: rate}) do
    is_binary(data) and rem(byte_size(data), 2) == 0 and is_integer(rate) and rate > 0
  end

  def valid?(_), do: false
end
