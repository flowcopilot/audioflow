defmodule AudioFlow.RTP.Reorder do
  @moduledoc """
  Bounded RTP reorder buffer keyed by 16-bit sequence number.

  `push/2` returns the packets that are now in order. Duplicates and packets
  older than the next expected sequence number are dropped. A packet further
  than `window` ahead returns `{:error, :rtp_reorder_limit}`. Sequence numbers
  wrap at 65 536. The owner decides how long to wait for a missing packet
  while `waiting?/1` is true, then calls `skip/1` or fails.
  """
  @enforce_keys [:window]
  defstruct [:window, expected: nil, pending: %{}]

  @type t :: %__MODULE__{window: 1..256, expected: nil | 0..65_535, pending: map()}

  def new(window) when is_integer(window) and window in 1..256, do: %__MODULE__{window: window}

  @spec push(t(), %{sequence_number: 0..65_535}) ::
          {:ok, [map()], t()} | {:error, :rtp_reorder_limit}
  def push(%__MODULE__{} = buffer, %{sequence_number: sequence} = packet) do
    expected = buffer.expected || sequence
    distance = rem(sequence - expected + 65_536, 65_536)

    cond do
      distance >= 32_768 or Map.has_key?(buffer.pending, sequence) ->
        {:ok, [], %{buffer | expected: expected}}

      distance > buffer.window ->
        {:error, :rtp_reorder_limit}

      true ->
        drain(%{buffer | expected: expected, pending: Map.put(buffer.pending, sequence, packet)})
    end
  end

  @doc "True while later packets wait for a missing one."
  def waiting?(%__MODULE__{pending: pending}), do: map_size(pending) > 0

  @doc """
  Gives up on the missing packets before the oldest buffered one. Returns the
  number of skipped sequence numbers and the packets that are now in order.
  """
  @spec skip(t()) :: {non_neg_integer(), [map()], t()}
  def skip(%__MODULE__{pending: pending} = buffer) when map_size(pending) == 0,
    do: {0, [], buffer}

  def skip(%__MODULE__{} = buffer) do
    next =
      Enum.min_by(Map.keys(buffer.pending), &rem(&1 - buffer.expected + 65_536, 65_536))

    lost = rem(next - buffer.expected + 65_536, 65_536)
    {:ok, packets, buffer} = drain(%{buffer | expected: next})
    {lost, packets, buffer}
  end

  defp drain(buffer, ready \\ []) do
    case Map.pop(buffer.pending, buffer.expected) do
      {nil, _} ->
        {:ok, Enum.reverse(ready), buffer}

      {packet, rest} ->
        drain(
          %{buffer | pending: rest, expected: rem(buffer.expected + 1, 65_536)},
          [packet | ready]
        )
    end
  end
end
