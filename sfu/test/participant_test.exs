defmodule AudioFlowSFU.ParticipantTest do
  use ExUnit.Case, async: false
  alias AudioFlowSFU.Native
  alias AudioFlowSFU.Participant
  alias AudioFlowSFU.TestAgent

  defp queue_length(pid), do: Process.info(pid, :message_queue_len) |> elem(1)

  test "forward drops media for a local subscriber with a long queue" do
    # A process that never reads its mailbox, as a stuck participant.
    stuck = spawn(fn -> Process.sleep(:infinity) end)
    healthy = self()

    assert Participant.forward([stuck, healthy], "TR_1", :packet) == 0
    assert_receive {Participant, :rtp, "TR_1", :packet}

    for _ <- 1..1_100, do: send(stuck, :queued)
    queued = queue_length(stuck)

    assert Participant.forward([stuck, healthy], "TR_1", :packet) == 1
    assert_receive {Participant, :rtp, "TR_1", :packet}
    assert queue_length(stuck) == queued
  end

  test "participants run with a heap limit" do
    agent = TestAgent.start(self())
    {:ok, join} = Native.join("heap-#{System.unique_integer([:positive])}", "agent", agent)

    assert {:max_heap_size, %{size: size, kill: true}} =
             Process.info(join.participant, :max_heap_size)

    assert size > 0
  end
end
