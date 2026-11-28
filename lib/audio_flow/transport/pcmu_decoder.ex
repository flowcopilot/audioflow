defmodule AudioFlow.Transport.PCMUDecoder do
  @moduledoc """
  PCMU (G.711 μ-law, 8 kHz) payloads for `AudioFlow.Transport.RtpInput`. The
  state is the `AudioFlow.Telephony.RateConverter` that raises the audio to
  16 kHz; start with `new/0`.
  """
  @behaviour AudioFlow.Transport.RtpInput
  alias AudioFlow.Telephony.MuLaw
  alias AudioFlow.Telephony.RateConverter

  @doc "The decoder in the form that `AudioFlow.Transport.RtpInput.restart/3` takes."
  def new, do: {__MODULE__, %RateConverter{}}

  @impl AudioFlow.Transport.RtpInput
  def decode(payload, converter) do
    {pcm, converter} = RateConverter.up(MuLaw.decode(payload), converter)
    {pcm, byte_size(payload), converter}
  end
end
