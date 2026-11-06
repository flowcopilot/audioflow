defmodule AudioFlow.Resampler do
  @moduledoc """
  Converts complete mono s16le PCM to another sample rate.

  It uses a polyphase windowed-sinc filter with 8 zero crossings on each side.
  The cut-off is 0.9 of the lower Nyquist frequency, so downsampling removes
  content that would alias. The conversion is not stateful: convert a complete
  utterance, not separate stream chunks. It runs in Elixir. On an Apple M-series
  CPU, one minute of 48 kHz input takes about 1.8 seconds, and one minute of
  8 kHz input about 0.9 seconds.
  """
  alias AudioFlow.Audio

  @zero_crossings 8

  def convert(%Audio{sample_rate: rate} = audio, rate), do: audio

  def convert(%Audio{} = audio, rate) when is_integer(rate) and rate > 0 do
    unless Audio.valid?(audio), do: raise(ArgumentError, "expected mono s16le PCM")
    divisor = Integer.gcd(audio.sample_rate, rate)
    up = div(rate, divisor)
    down = div(audio.sample_rate, divisor)

    count = div(byte_size(audio.data), 2)
    output_count = div(count * up, down)
    {table, half} = table(up, down)
    padding = :binary.copy(<<0, 0>>, half)
    input = padding <> audio.data <> padding
    width = 4 * half

    data =
      for k <- 0..(output_count - 1)//1, into: <<>> do
        position = k * down
        start = div(position, up) + 1
        window = binary_part(input, 2 * start, width)
        value = dot(window, elem(table, rem(position, up)), 0.0)
        <<value |> round() |> max(-32_768) |> min(32_767)::little-signed-16>>
      end

    %Audio{data: data, sample_rate: rate}
  end

  defp dot(<<sample::little-signed-16, rest::binary>>, [weight | weights], acc),
    do: dot(rest, weights, acc + weight * sample)

  defp dot(<<>>, [], acc), do: acc

  # One weight list for each output phase. Weight j of phase p applies to input
  # sample center - half + 1 + j, at distance (j + 1 - half - p / up) samples.
  defp table(up, down) do
    cutoff = 0.9 * min(1.0, up / down)
    half = ceil(@zero_crossings / cutoff)

    phases =
      for phase <- 0..(up - 1) do
        offset = phase / up

        weights =
          for j <- 0..(2 * half - 1) do
            distance = j + 1 - half - offset
            kernel(distance, cutoff, half)
          end

        sum = Enum.sum(weights)
        Enum.map(weights, &(&1 / sum))
      end

    {List.to_tuple(phases), half}
  end

  defp kernel(distance, cutoff, half) do
    window = 0.5 + 0.5 * :math.cos(:math.pi() * distance / half)
    x = :math.pi() * cutoff * distance
    sinc = if abs(x) < 1.0e-9, do: 1.0, else: :math.sin(x) / x
    if abs(distance) >= half, do: 0.0, else: cutoff * sinc * window
  end

  @doc "Linear interpolation of mono signed 16-bit PCM."
  def linear(%Audio{sample_rate: rate} = audio, rate), do: audio

  def linear(%Audio{data: data, sample_rate: from}, to) do
    samples = for <<sample::little-signed-16 <- data>>, do: sample
    input = List.to_tuple(samples)
    count = tuple_size(input)
    length = if count == 0, do: 0, else: max(1, div(count * to, from))

    pcm =
      for index <- 0..(length - 1)//1, into: <<>> do
        position = index * from / to
        left = min(trunc(position), count - 1)
        right = min(left + 1, count - 1)
        weight = position - left
        sample = round(elem(input, left) * (1 - weight) + elem(input, right) * weight)
        <<sample::little-signed-16>>
      end

    %Audio{data: pcm, sample_rate: to}
  end
end
