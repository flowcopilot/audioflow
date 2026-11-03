defmodule AudioFlow.TelephonyTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Telephony.MuLaw
  alias AudioFlow.Telephony.RateConverter

  test "G.711 reference values and every decoded codeword round trip" do
    assert MuLaw.decode(<<255, 127, 0, 128, 254, 126>>) ==
             <<0::little-signed-16, 0::little-signed-16, -32_124::little-signed-16,
               32_124::little-signed-16, 8::little-signed-16, -8::little-signed-16>>

    for byte <- 0..255 do
      assert MuLaw.encode(MuLaw.decode(<<byte>>)) == if(byte == 127, do: <<255>>, else: <<byte>>)
    end
  end

  test "conversion is independent of network chunk boundaries and preserves duration" do
    pcm = for i <- 1..801, into: <<>>, do: <<round(12_000 * :math.sin(i / 5))::little-signed-16>>

    for direction <- [:up, :down] do
      {whole, _} = apply(RateConverter, direction, [pcm, %RateConverter{}])
      <<first::binary-size(318), rest::binary>> = pcm
      {a, state} = apply(RateConverter, direction, [first, %RateConverter{}])
      {b, _} = apply(RateConverter, direction, [rest, state])
      assert a <> b == whole
      assert byte_size(whole) == if(direction == :up, do: 3204, else: 800)
    end
  end

  test "downsampler suppresses frequencies above the telephone passband" do
    rms = fn frequency ->
      pcm =
        for i <- 0..15_999,
            into: <<>>,
            do:
              <<round(10_000 * :math.sin(2 * :math.pi() * frequency * i / 16_000))::little-signed-16>>

      {data, _} = RateConverter.down(pcm, %RateConverter{})
      samples = for <<s::little-signed-16 <- data>>, do: s * s
      :math.sqrt(Enum.sum(Enum.drop(samples, 100)) / 7900)
    end

    assert rms.(1000) > 6500
    assert rms.(6000) < 100
  end
end
