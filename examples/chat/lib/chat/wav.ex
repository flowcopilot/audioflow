defmodule Chat.Wav do
  @moduledoc "Wraps mono s16le PCM in a WAV header for the browser audio player."

  def encode(pcm, rate) do
    data = IO.iodata_to_binary(pcm)
    size = byte_size(data)

    <<"RIFF", size + 36::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data", size::little-32,
      data::binary>>
  end
end
