defmodule AudioFlow.RTP.Reorder do
  @moduledoc """
  Bounded RTP reorder buffer keyed by 16-bit sequence number.

  `push/2` returns the packets that are now in order. Duplicates and packets
  older than the next expected sequence number are dropped. Sequence numbers
  wrap at 65 536. The owner decides how long to wait for a missing packet
  while `waiting?/1` is true, then calls `skip/1`.

  A new stream has no known first sequence number, so the buffer holds its
  first packets until three are buffered (or the owner calls `skip/1`) and
  lets a packet that arrives early take its place at the front.

  A packet further than `window` ahead means a long burst loss. The buffer
  does not wait for the missing packets: it releases what it holds, starts a
  new run at that packet and returns `{:resync, lost, packets, buffer}`. The
  owner decides what the `lost` sequence numbers become.
  """
  @enforce_keys [:window]
  defstruct [:window, expected: nil, pending: %{}, initial: true]

  @type t :: %__MODULE__{
          window: 1..256,
          expected: nil | 0..65_535,
          pending: map(),
          initial: boolean()
        }

  # Packets to buffer at the start of a stream before the first release.
  @initial_hold 3

  def new(window) when is_integer(window) and window in 1..256, do: %__MODULE__{window: window}

  @spec push(t(), %{sequence_number: 0..65_535}) ::
          {:ok, [map()], t()} | {:resync, non_neg_integer(), [map()], t()}
  def push(%__MODULE__{} = buffer, %{sequence_number: sequence} = packet) do
    expected = buffer.expected || sequence
    distance = rem(sequence - expected + 65_536, 65_536)

    cond do
      Map.has_key?(buffer.pending, sequence) ->
        {:ok, [], buffer}

      distance >= 32_768 ->
        early(buffer, packet, expected, 65_536 - distance)

      distance > buffer.window ->
        resync(buffer, packet)

      true ->
        accept(%{buffer | expected: expected}, packet)
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
    {:ok, packets, buffer} = drain(%{buffer | expected: next, initial: false})
    {lost, packets, buffer}
  end

  # A packet from before the first one only belongs to the stream if the
  # stream has not started yet. Later it is late and dropped.
  defp early(%{initial: true, expected: expected} = buffer, packet, expected, back)
       when back <= buffer.window,
       do: accept(%{buffer | expected: packet.sequence_number}, packet)

  defp early(buffer, _packet, expected, _back), do: {:ok, [], %{buffer | expected: expected}}

  defp accept(buffer, %{sequence_number: sequence} = packet) do
    buffer = %{buffer | pending: Map.put(buffer.pending, sequence, packet)}

    if buffer.initial and map_size(buffer.pending) < min(@initial_hold, buffer.window),
      do: {:ok, [], buffer},
      else: drain(%{buffer | initial: false})
  end

  defp resync(buffer, %{sequence_number: sequence} = packet) do
    {lost_before, released, buffer} = skip(buffer)
    gap = rem(sequence - buffer.expected + 65_536, 65_536)

    {:ok, packets, buffer} =
      drain(%{buffer | expected: sequence, initial: false, pending: %{sequence => packet}})

    {:resync, lost_before + gap, released ++ packets, buffer}
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
