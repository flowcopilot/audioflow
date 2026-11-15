defmodule AudioFlow.Telephony.RateConverter do
  @moduledoc """
  Stateful 8/16 kHz conversion for narrowband telephony, on `AudioFlow.Resampler`.
  A converter works in the direction of its first call. It holds about 2 ms of
  audio, which `finish/1` returns.
  """
  alias AudioFlow.Resampler

  defstruct [:resampler]

  def up(data, state), do: convert(data, state, 8000, 16_000)
  def down(data, state), do: convert(data, state, 16_000, 8000)

  @doc "Returns the held audio and a new converter."
  def finish(%__MODULE__{resampler: nil} = state), do: {<<>>, state}
  def finish(%__MODULE__{resampler: resampler}), do: {Resampler.flush(resampler), %__MODULE__{}}

  defp convert(data, state, from, to) when rem(byte_size(data), 2) == 0 do
    resampler = state.resampler || Resampler.new(from, to)
    {Resampler.push(resampler, data), %{state | resampler: resampler}}
  end
end
