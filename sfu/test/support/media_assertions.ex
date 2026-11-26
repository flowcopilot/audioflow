defmodule AudioFlowSFU.MediaAssertions do
  @moduledoc false
  # Assertions over TestClient messages.
  import ExUnit.Assertions
  alias AudioFlowSFU.TestClient

  def connected(client) do
    assert_receive {:client, ^client, :client_connected}, 5000
  end

  def payload(n), do: <<n::8, :binary.copy(<<0xAB>>, 59)::binary>>

  # Publishes until the subscriber receives one packet, then checks a run of
  # packets in order. The first packets can arrive before the subscriber's
  # transceiver is negotiated.
  def assert_forwarded(publisher, subscriber) do
    Enum.reduce_while(1..200, nil, fn n, _ ->
      TestClient.send_audio(publisher, payload(n))

      receive do
        {:client, ^subscriber, {:rtp, _}} -> {:halt, :ok}
      after
        20 -> {:cont, nil}
      end
    end)

    flush_rtp(subscriber)

    for n <- 1000..1009, do: TestClient.send_audio(publisher, payload(rem(n, 256)))

    received =
      for _ <- 1..10 do
        assert_receive {:client, ^subscriber, {:rtp, packet}}, 2000
        packet.payload
      end

    assert received == for(n <- 1000..1009, do: payload(rem(n, 256)))
  end

  # Offers can follow each other; waits for one that matches.
  def await_offer(client, match?) do
    assert_receive {:client, ^client, {:offer, mids}}, 5000
    if match?.(mids), do: mids, else: await_offer(client, match?)
  end

  def flush_rtp(client) do
    receive do
      {:client, ^client, {:rtp, _}} -> flush_rtp(client)
    after
      50 -> :ok
    end
  end
end
