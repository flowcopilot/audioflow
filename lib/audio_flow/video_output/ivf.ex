defmodule AudioFlow.VideoOutput.IVF do
  @moduledoc """
  Bounded VP8 IVF file input for encoded video publication. This does not decode
  or infer video. Returns frame payloads with microsecond presentation timestamps.
  Accepts version 0, a 32-byte header and at most 8 MB / 256 KB per frame.
  """
  def read(path) do
    with {:ok, %{size: size}} when size <= 8_388_608 <- File.stat(path),
         {:ok, binary} <- File.read(path) do
      decode(binary)
    else
      {:ok, _} -> {:error, :file_too_large}
      error -> error
    end
  end

  def decode(
        <<"DKIF", 0::little-16, 32::little-16, "VP80", width::little-16, height::little-16,
          rate::little-32, scale::little-32, count::little-32, _::32, frames::binary>> = binary
      )
      when width > 0 and height > 0 and rate > 0 and scale > 0 and
             byte_size(binary) <= 8_388_608 do
    with {:ok, frames} <- frames(frames, rate, scale, -1, []) do
      if length(frames) == count,
        do: {:ok, %{width: width, height: height, frames: frames}},
        else: {:error, :invalid_frame_count}
    end
  end

  def decode(_), do: {:error, :invalid_ivf}

  defp frames(<<>>, _, _, _, acc), do: {:ok, Enum.reverse(acc)}

  defp frames(<<size::little-32, ts::little-64, rest::binary>>, rate, scale, previous, acc)
       when size in 1..262_144 and byte_size(rest) >= size and ts >= previous do
    <<frame::binary-size(^size), rest::binary>> = rest

    frames(rest, rate, scale, ts, [
      %{data: frame, pts_us: div(ts * scale * 1_000_000, rate)} | acc
    ])
  end

  defp frames(_, _, _, _, _), do: {:error, :invalid_frame}
end
