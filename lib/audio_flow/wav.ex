defmodule AudioFlow.Wav do
  @moduledoc """
  Reads mono signed 16-bit PCM WAV data as `AudioFlow.Audio`.

  Other encodings, channel counts and sample sizes return
  `{:error, :unsupported_wav}`. Convert them first, for example with
  `ffmpeg -i input -ac 1 -ar 16000 -sample_fmt s16 output.wav`.
  """
  alias AudioFlow.Audio

  def read(path) do
    with {:ok, data} <- File.read(path), do: decode(data)
  end

  def decode(<<"RIFF", _size::little-32, "WAVE", chunks::binary>>), do: chunks(chunks, nil)
  def decode(_), do: {:error, :invalid_wav}

  def encode(%Audio{data: data, sample_rate: rate}) do
    size = byte_size(data)

    <<"RIFF", size + 36::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data", size::little-32,
      data::binary>>
  end

  defp chunks(<<"fmt ", size::little-32, body::binary-size(size), rest::binary>>, _format) do
    format =
      case body do
        <<format::little-16, 1::little-16, rate::little-32, _::little-32, 2::little-16,
          16::little-16, _::binary>>
        when format in [1, 0xFFFE] and rate > 0 ->
          rate

        _ ->
          :unsupported
      end

    chunks(skip_pad(rest, size), format)
  end

  defp chunks(<<"data", _::little-32, _::binary>>, :unsupported), do: {:error, :unsupported_wav}

  defp chunks(<<"data", size::little-32, rest::binary>>, rate) when is_integer(rate) do
    # Streamed WAV files can have an unknown (0 or 0xFFFFFFFF) data size.
    size = if size == 0 or size > byte_size(rest), do: byte_size(rest), else: size
    size = size - rem(size, 2)
    {:ok, %Audio{data: binary_part(rest, 0, size), sample_rate: rate}}
  end

  defp chunks(<<_id::binary-size(4), size::little-32, rest::binary>>, format)
       when byte_size(rest) >= size,
       do: chunks(skip_pad(binary_part(rest, size, byte_size(rest) - size), size), format)

  defp chunks(_, _), do: {:error, :invalid_wav}

  # RIFF chunks are padded to an even size.
  defp skip_pad(<<_, rest::binary>>, size) when rem(size, 2) == 1, do: rest
  defp skip_pad(rest, _size), do: rest
end
