defmodule AudioFlowSFU.TestAgent do
  @moduledoc false
  # A stand-in for an AudioFlow agent: it relays every SFU message to the
  # test process and sends messages to a participant on request. It uses no
  # SFU module, as an agent on another node would not.

  def start(test), do: spawn(fn -> loop(test) end)

  @doc "Sends one RTP map for `track_sid` through the agent process."
  def send_rtp(agent, participant, track_sid, sequence, payload) do
    rtp = %{sequence_number: sequence, timestamp: sequence * 960, marker: false, payload: payload}
    send(agent, {:send, participant, {:audio_flow_sfu, 1, {:rtp, track_sid, rtp}}})
  end

  defp loop(test) do
    receive do
      {:send, participant, message} ->
        send(participant, message)
        loop(test)

      message ->
        send(test, {:agent, self(), message})
        loop(test)
    end
  end
end
