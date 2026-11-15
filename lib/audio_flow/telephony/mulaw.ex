defmodule AudioFlow.Telephony.MuLaw do
  @moduledoc """
  G.711 μ-law codec on FFmpeg, through `membrane_g711_ffmpeg_plugin`. PCM
  values are signed 16-bit little-endian.
  """
  alias Membrane.G711.FFmpeg.Decoder
  alias Membrane.G711.FFmpeg.Encoder

  def decode(<<>>), do: <<>>

  def decode(data) when is_binary(data) do
    {:ok, frames} = Decoder.Native.decode(data, codec(:decoder))
    IO.iodata_to_binary(frames)
  end

  def encode(<<>>), do: <<>>

  def encode(data) when rem(byte_size(data), 2) == 0 do
    {:ok, frames} = Encoder.Native.encode(data, codec(:encoder))
    IO.iodata_to_binary(frames)
  end

  # An FFmpeg codec context is not safe to share, so each process keeps its own.
  defp codec(kind) do
    key = {__MODULE__, kind}

    with nil <- Process.get(key) do
      {:ok, codec} =
        if kind == :decoder,
          do: Decoder.Native.create(:PCMU),
          else: Encoder.Native.create(:s16le, :PCMU)

      Process.put(key, codec)
      codec
    end
  end
end
