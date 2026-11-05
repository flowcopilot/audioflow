defmodule AudioFlow.Telephony.MuLaw do
  @moduledoc "G.711 μ-law codec. PCM values are signed 16-bit little-endian."
  import Bitwise

  def decode(data) do
    for <<byte <- data>>, into: <<>> do
      value = bxor(byte, 255)
      magnitude = (((value &&& 15) <<< 3) + 132) <<< (value >>> 4 &&& 7)
      sample = if (value &&& 128) == 0, do: magnitude - 132, else: 132 - magnitude
      <<sample::little-signed-16>>
    end
  end

  def encode(data) when rem(byte_size(data), 2) == 0 do
    for <<sample::little-signed-16 <- data>>, into: <<>> do
      mask = if sample < 0, do: 127, else: 255
      value = min(abs(sample), 32_635) + 132
      exponent = Enum.find(7..0//-1, 0, fn e -> value >= 128 <<< e end)
      mantissa = value >>> (exponent + 3) &&& 15
      <<bxor(exponent <<< 4 ||| mantissa, mask)>>
    end
  end
end
