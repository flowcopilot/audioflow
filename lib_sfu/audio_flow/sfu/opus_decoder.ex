defmodule AudioFlow.SFU.OpusDecoder do
  @moduledoc """
  Opus payloads for `AudioFlow.Transport.RtpInput`, on the decoder of
  `membrane_opus_plugin`. Output is 16 kHz mono PCM.

  Browsers can send stereo Opus (`stereo=1`). The TOC byte says how many
  channels a packet has; a stereo packet is decoded in stereo and mixed down.
  """
  @behaviour AudioFlow.Transport.RtpInput
  alias AudioFlow.Resampler
  alias Membrane.Opus.Decoder.Native, as: Decoder

  @doc "The decoder in the form that `AudioFlow.Transport.RtpInput.restart/3` takes."
  def new, do: {__MODULE__, %{decoders: %{}, resampler: Resampler.new(48_000, 16_000)}}

  @impl AudioFlow.Transport.RtpInput
  def decode(<<_::5, stereo::1, _::2, _::binary>> = payload, state) do
    channels = stereo + 1
    decoder = Map.get_lazy(state.decoders, channels, fn -> Decoder.create(48_000, channels) end)
    pcm = Decoder.decode_packet(decoder, payload)
    samples = div(byte_size(pcm), 2 * channels)
    pcm = if channels == 2, do: downmix(pcm), else: pcm

    {Resampler.push(state.resampler, pcm), samples,
     %{state | decoders: Map.put(state.decoders, channels, decoder)}}
  end

  def decode(_payload, state), do: {<<>>, 0, state}

  defp downmix(pcm) do
    for <<l::little-signed-16, r::little-signed-16 <- pcm>>,
      into: <<>>,
      do: <<div(l + r, 2)::little-signed-16>>
  end
end
