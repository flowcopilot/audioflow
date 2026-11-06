defmodule AudioFlow.ResamplerTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Audio
  alias AudioFlow.Resampler

  defp tone(frequency, rate, seconds, amplitude \\ 10_000) do
    data =
      for i <- 0..(round(rate * seconds) - 1), into: <<>> do
        value = round(amplitude * :math.sin(2 * :math.pi() * frequency * i / rate))
        <<value::little-signed-16>>
      end

    %Audio{data: data, sample_rate: rate}
  end

  # Root mean square of the middle half, away from the edges.
  defp rms(%Audio{data: data}) do
    samples = for <<s::little-signed-16 <- data>>, do: s
    count = length(samples)
    middle = Enum.slice(samples, div(count, 4), div(count, 2))
    :math.sqrt(Enum.sum(Enum.map(middle, &(&1 * &1))) / length(middle))
  end

  test "the same rate returns the input" do
    audio = tone(440, 16_000, 0.01)
    assert Resampler.convert(audio, 16_000) == audio
  end

  test "common rates convert to 16 kHz with the expected length and level" do
    for rate <- [8000, 22_050, 24_000, 44_100, 48_000] do
      input = tone(1000, rate, 0.25)
      output = Resampler.convert(input, 16_000)
      assert output.sample_rate == 16_000
      assert byte_size(output.data) == div(byte_size(input.data) * 16_000, rate * 2) * 2
      assert_in_delta rms(output), rms(input), rms(input) * 0.03
    end
  end

  test "downsampling removes content above the new Nyquist frequency" do
    output = Resampler.convert(tone(11_000, 48_000, 0.25), 16_000)
    assert rms(output) < 100
  end

  test "invalid input and rates are rejected" do
    assert_raise ArgumentError, fn ->
      Resampler.convert(%Audio{data: <<0>>, sample_rate: 8000}, 16_000)
    end

    assert_raise FunctionClauseError, fn -> Resampler.convert(tone(1, 8000, 0.01), 0) end
  end
end
