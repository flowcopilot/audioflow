defmodule AudioFlow.Telephony.Packetizer do
  @moduledoc "Stateful PCM conversion to 20 ms G.711 μ-law packets, with a padded final packet."
  alias AudioFlow.Audio
  alias AudioFlow.Telephony.MuLaw
  alias AudioFlow.Telephony.RateConverter

  defstruct rate: nil, converter: %RateConverter{}, pending: <<>>, active?: false

  def format(state, rate), do: %{state | rate: rate, converter: %RateConverter{}}

  def push(%Audio{data: data, sample_rate: rate}, state) do
    {data, converter} =
      if rate == 16_000,
        do: RateConverter.down(data, state.converter),
        else: {data, state.converter}

    split(state.pending <> MuLaw.encode(data), %{
      state
      | rate: rate,
        converter: converter,
        active?: true
    })
  end

  def finish(state) do
    {tail, _} =
      if state.active? and state.rate == 16_000,
        do: RateConverter.finish_down(state.converter),
        else: {<<>>, state.converter}

    data = state.pending <> MuLaw.encode(tail)
    padding = rem(160 - rem(byte_size(data), 160), 160)
    split(data <> :binary.copy(<<255>>, padding), %__MODULE__{rate: state.rate})
  end

  defp split(data, state) do
    packets = for <<packet::binary-size(160) <- data>>, do: packet
    size = byte_size(data)
    remaining = rem(size, 160)
    {packets, %{state | pending: binary_part(data, size - remaining, remaining)}}
  end
end
