defmodule AudioFlow.RTP.ReorderTest do
  use ExUnit.Case, async: true
  alias AudioFlow.RTP.Reorder

  defp packet(sequence), do: %{sequence_number: sequence}
  defp sequences(packets), do: Enum.map(packets, & &1.sequence_number)

  defp push_all(buffer, sequences) do
    Enum.reduce(sequences, {[], buffer}, fn sequence, {ready, buffer} ->
      {:ok, packets, buffer} = Reorder.push(buffer, packet(sequence))
      {ready ++ sequences(packets), buffer}
    end)
  end

  test "releases packets in order across the 16-bit wrap" do
    {ready, buffer} = push_all(Reorder.new(8), [65_534, 0, 65_535, 1])
    assert ready == [65_534, 65_535, 0, 1]
    refute Reorder.waiting?(buffer)
  end

  test "drops duplicates and packets older than the next expected one" do
    {ready, buffer} = push_all(Reorder.new(8), [10, 12, 12, 11, 9, 11])
    assert ready == [10, 11, 12]
    refute Reorder.waiting?(buffer)
  end

  test "a packet beyond the window resyncs and reports the lost count" do
    {[100, 101, 102], buffer} = push_all(Reorder.new(4), [100, 101, 102])
    assert {:ok, [], buffer} = Reorder.push(buffer, packet(104))

    assert {:resync, 6, packets, buffer} = Reorder.push(buffer, packet(110))
    assert sequences(packets) == [104, 110]
    refute Reorder.waiting?(buffer)
    assert {:ok, [%{sequence_number: 111}], _} = Reorder.push(buffer, packet(111))
  end

  test "resync across the wrap counts only the missing sequence numbers" do
    {[65_530, 65_531, 65_532], buffer} = push_all(Reorder.new(4), [65_530, 65_531, 65_532])
    assert {:resync, 20, [%{sequence_number: 17}], _} = Reorder.push(buffer, packet(17))
  end

  test "a stream start tolerates a packet that arrives before the first one" do
    {ready, buffer} = push_all(Reorder.new(8), [11, 10, 12])
    assert ready == [10, 11, 12]
    refute Reorder.waiting?(buffer)
  end

  test "skip releases the held start of a stream without counting loss" do
    {[], buffer} = push_all(Reorder.new(8), [11, 12])
    assert Reorder.waiting?(buffer)
    assert {0, packets, buffer} = Reorder.skip(buffer)
    assert sequences(packets) == [11, 12]
    assert {:ok, [], _} = Reorder.push(buffer, packet(10))
  end

  test "skip gives up on a gap and reports the lost count" do
    {[1], buffer} = push_all(Reorder.new(16), [1, 5, 4])
    assert Reorder.waiting?(buffer)
    assert {2, packets, buffer} = Reorder.skip(buffer)
    assert sequences(packets) == [4, 5]
    refute Reorder.waiting?(buffer)
    assert {0, [], ^buffer} = Reorder.skip(buffer)
  end

  test "skip measures the gap across the wrap" do
    {[65_535], buffer} = push_all(Reorder.new(16), [65_535, 2, 3])
    assert {2, [%{sequence_number: 2}, %{sequence_number: 3}], _} = Reorder.skip(buffer)
  end
end
