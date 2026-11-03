defmodule AudioFlow.PlayoutTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Audio
  alias AudioFlow.Playout

  defp audio, do: %Audio{data: <<0, 0>>, sample_rate: 16_000}

  test "ack before checkpoint does not lose progress, and repeated ack is idempotent" do
    state = Playout.new() |> Playout.audio(audio())
    assert {:ok, state} = Playout.acknowledge(state, 62_500)
    assert Playout.heard_bytes(state) == 0
    state = Playout.checkpoint(state, 7)
    assert Playout.heard_bytes(state) == 7
    assert {:ok, ^state} = Playout.acknowledge(state, 62_500)
    assert {:error, :invalid_playback_offset} = Playout.acknowledge(state, -1)
  end

  test "a text chunk with no audio never becomes heard via a later chunk" do
    state = Playout.new() |> Playout.audio(audio()) |> Playout.checkpoint(7)
    state = state |> Playout.checkpoint(12) |> Playout.audio(audio()) |> Playout.checkpoint(18)
    assert {:ok, state} = Playout.acknowledge(state, 125_000)
    assert Playout.heard_bytes(state) == 7
  end
end
