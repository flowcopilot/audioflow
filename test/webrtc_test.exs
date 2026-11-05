if System.get_env("AUDIOFLOW_WEBRTC") == "1" do
  defmodule AudioFlow.WebRTCTest do
    use ExUnit.Case, async: true
    alias AudioFlow.VideoOutput.IVF
    alias AudioFlow.WebRTC

    test "real offer/answer, trickled ICE, DTLS and audio/video RTP with clocks and stale-turn rejection" do
      a = start_supervised!({WebRTC, owner: self()}, id: :a)
      b = start_supervised!({WebRTC, owner: self()}, id: :b)
      {:ok, offer} = WebRTC.offer(a)
      assert offer["sdp"] =~ "PCMU/8000"
      assert offer["sdp"] =~ "VP8/90000"
      assert :ok = WebRTC.signal(b, offer)
      connect(a, b, MapSet.new())
      key = make_ref()
      assert :ok = WebRTC.start_turn(a, key)
      pcmu = :binary.copy(<<255>>, 160)
      assert :ok = WebRTC.publish(a, key, :audio, pcmu, 20_000)
      assert_receive {WebRTC, ^b, {:media, {:rtp, _, nil, packet}}}, 3000
      assert packet.payload == pcmu
      assert packet.timestamp == 160

      {:ok, %{frames: [%{data: frame} | _]}} =
        IVF.read("examples/network/assets/test-pattern.ivf")

      fragment_count = div(byte_size(frame) + 1198, 1199)
      assert :ok = WebRTC.publish(a, key, :video, frame, 20_000)

      packets =
        for _ <- 1..fragment_count do
          assert_receive {WebRTC, ^b, {:media, {:rtp, _, nil, packet}}}, 3000
          packet
        end

      assert Enum.map(packets, & &1.timestamp) == List.duplicate(1800, fragment_count)
      assert Enum.map(packets, & &1.marker) == List.duplicate(false, fragment_count - 1) ++ [true]

      assert Enum.map(packets, fn p -> binary_part(p.payload, 0, 1) end) == [
               <<16>> | List.duplicate(<<0>>, fragment_count - 1)
             ]

      assert Enum.map_join(packets, fn p ->
               binary_part(p.payload, 1, byte_size(p.payload) - 1)
             end) == frame

      assert {:error, :regressing_timestamp} = WebRTC.publish(a, key, :video, frame, 0)
      assert {:error, :invalid_media} = WebRTC.publish(a, key, :audio, <<0>>, 40_000)
      assert :ok = WebRTC.flush(a, key)
      assert {:error, :stale_turn} = WebRTC.publish(a, key, :audio, pcmu, 40_000)
    end

    test "unnegotiated peers close on deadline and stop their connection" do
      {:ok, peer} = WebRTC.start_link(owner: self(), negotiation_timeout_ms: 20)
      pc = :sys.get_state(peer).pc
      ref = Process.monitor(peer)
      pc_ref = Process.monitor(pc)
      assert_receive {:DOWN, ^ref, :process, ^peer, :normal}
      assert_receive {:DOWN, ^pc_ref, :process, ^pc, _}
    end

    test "rejects malformed signaling and cleans up when its owner dies" do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, peer} = WebRTC.start_link(owner: owner)
      assert {:error, :invalid_signal} = WebRTC.signal(peer, %{"type" => "answer"})

      assert {:error, :invalid_signal} =
               WebRTC.signal(peer, %{"type" => "candidate", "candidate" => %{}})

      assert :ok = WebRTC.signal(peer, %{"type" => "candidate", "candidate" => nil})
      pc = :sys.get_state(peer).pc
      ref = Process.monitor(pc)
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pc, _}
    end

    defp connect(a, b, connected) do
      if MapSet.size(connected) < 2 do
        receive do
          {WebRTC, source, {:signal, message}} ->
            assert :ok = WebRTC.signal(if(source == a, do: b, else: a), message)
            connect(a, b, connected)

          {WebRTC, source, :connected} ->
            connect(a, b, MapSet.put(connected, source))

          {WebRTC, _, {:media, _}} ->
            connect(a, b, connected)
        after
          8000 -> flunk("local peers failed to negotiate")
        end
      end
    end
  end
end
