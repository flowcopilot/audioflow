defmodule AudioFlow.Telephony.RateConverter do
  @moduledoc """
  Stateful 8/16 kHz conversion for narrowband telephony. Upsampling uses linear
  interpolation; downsampling uses a 31-tap windowed-sinc low-pass FIR at 3.4 kHz.
  Filter delay is 15 input samples. This is not wideband audio restoration.
  """
  @taps (for n <- -15..15 do
           sinc =
             if n == 0, do: 0.425, else: :math.sin(2 * :math.pi() * 0.2125 * n) / (:math.pi() * n)

           sinc * (0.54 + 0.46 * :math.cos(:math.pi() * n / 15))
         end)
  @gain Enum.sum(@taps)
  defstruct previous: 0, history: List.duplicate(0, 30), phase: 0

  def up(data, state) when rem(byte_size(data), 2) == 0 do
    {samples, previous} =
      Enum.map_reduce(for(<<s::little-signed-16 <- data>>, do: s), state.previous, fn s, p ->
        {<<div(p + s, 2)::little-signed-16, s::little-signed-16>>, s}
      end)

    {IO.iodata_to_binary(samples), %{state | previous: previous}}
  end

  def down(data, state) when rem(byte_size(data), 2) == 0 do
    {samples, state} =
      Enum.map_reduce(for(<<s::little-signed-16 <- data>>, do: s), state, fn s, state ->
        history = [s | state.history]
        value = Enum.zip_with(history, @taps, &(&1 * &2)) |> Enum.sum()
        value = (value / @gain) |> round() |> max(-32768) |> min(32767)
        output = if state.phase == 1, do: <<value::little-signed-16>>, else: <<>>
        {output, %{state | history: Enum.take(history, 30), phase: 1 - state.phase}}
      end)

    {IO.iodata_to_binary(samples), state}
  end
end
