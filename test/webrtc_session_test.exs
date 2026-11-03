if System.get_env("AUDIOFLOW_WEBRTC") == "1" do
  defmodule AudioFlow.WebRTCSessionTest do
    use ExUnit.Case, async: false
    alias AudioFlow.Adapters.Demo
    alias AudioFlow.Audio
    alias AudioFlow.Telephony.MuLaw
    alias AudioFlow.Telephony.RateConverter
    alias AudioFlow.WebRTC
    alias AudioFlow.WebRTC.Session
    alias AudioFlow.WebRTC.Transport

    defmodule Detector do
      def init(_), do: {320, 16_000, nil}

      def predict(%Audio{data: data}, state) do
        speech = for(<<x::little-signed-16 <- data>>, do: abs(x)) |> Enum.max()
        {if(speech > 1000, do: 1.0, else: 0.0), state}
      end
    end

    defp function(fun), do: {AudioFlow.Adapters.Function, run: fun}

    defp pair(opts \\ []) do
      owner = self()

      session = [
        stt:
          function(fn audio, emit ->
            send(owner, {:input, audio})
            emit.("actual utterance")
          end),
        llm: function(fn "actual utterance", emit -> emit.("reply text") end),
        tts:
          function(fn "reply text", emit ->
            emit.(%Audio{data: :binary.copy(<<0x10, 0x27>>, 333), sample_rate: 16_000})
            emit.(%Audio{data: :binary.copy(<<0x10, 0x27>>, 1267), sample_rate: 16_000})
          end)
      ]

      bridge =
        start_supervised!(
          {Session,
           Keyword.merge(
             [
               owner: self(),
               session: session,
               vad: {Detector, []},
               voice_input: [min_speech_ms: 20, min_silence_ms: 20, pre_roll_ms: 0]
             ],
             opts
           )}
        )

      peer = start_supervised!({WebRTC, owner: self()})
      {:ok, offer} = WebRTC.offer(peer)
      :ok = Session.signal(bridge, offer)
      connect(peer, bridge, MapSet.new())
      {peer, bridge}
    end

    defp connect(a, b, ready) do
      if MapSet.size(ready) < 2 do
        receive do
          {WebRTC, ^a, {:signal, m}} ->
            :ok = Session.signal(b, m)
            connect(a, b, ready)

          {Session, ^b, {:signal, m}} ->
            :ok = WebRTC.signal(a, m)
            connect(a, b, ready)

          {WebRTC, ^a, :connected} ->
            connect(a, b, MapSet.put(ready, a))

          {Session, ^b, :connected} ->
            connect(a, b, MapSet.put(ready, b))
        after
          5000 -> flunk("local peer negotiation timeout")
        end
      end
    end

    defp speak(peer, pts \\ 0) do
      key = make_ref()
      :ok = WebRTC.start_turn(peer, key)

      :ok =
        WebRTC.publish(peer, key, :audio, MuLaw.encode(:binary.copy(<<0x10, 0x27>>, 160)), pts)

      :ok = WebRTC.publish(peer, key, :audio, :binary.copy(<<255>>, 160), pts + 20_000)
      :ok = WebRTC.publish(peer, key, :audio, :binary.copy(<<255>>, 160), pts + 40_000)
    end

    defp packet(peer) do
      receive do
        {WebRTC, ^peer, {:media, {:rtp, _, nil, p}}} -> p
      after
        3000 -> flunk("RTP timeout")
      end
    end

    defp raw(peer, seq, timestamp, payload \\ :binary.copy(<<255>>, 160)) do
      s = :sys.get_state(peer)

      ExWebRTC.PeerConnection.send_rtp(
        s.pc,
        s.tracks.audio,
        ExRTP.Packet.new(payload, sequence_number: seq, timestamp: timestamp)
      )
    end

    test "real RTP reorders across sequence/timestamp wrap; missing packet deadline closes all work" do
      {peer, bridge} = pair(gap_timeout_ms: 80)
      s = :sys.get_state(bridge)
      raw(peer, 65_535, 4_294_967_136)
      await(fn -> :sys.get_state(bridge).expected == 0 end)
      raw(peer, 1, 160)
      await(fn -> map_size(:sys.get_state(bridge).reorder) == 1 end)
      raw(peer, 0, 0)
      await(fn -> :sys.get_state(bridge).expected == 2 end)
      assert :sys.get_state(bridge).reorder == %{}
      # Sequence 2 is lost. The next packet cannot enter VAD out of order.
      raw(peer, 3, 480)
      refs = for pid <- [bridge, s.peer, s.session, s.transport], do: {pid, Process.monitor(pid)}
      assert_receive {Session, ^bridge, {:error, :rtp_gap_timeout}}, 1000
      for {pid, ref} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 1000)
    end

    test "invalid PCMU packet length fails closed" do
      {peer, bridge} = pair()
      raw(peer, 0, 0, <<255>>)
      assert_receive {Session, ^bridge, {:error, :unsupported_rtp}}, 1000
    end

    test "owner death cleans up a connected bridge" do
      target = self()
      owner = spawn(fn -> relay(target) end)
      {_, bridge} = pair(owner: owner)
      s = :sys.get_state(bridge)

      refs = for pid <- [bridge, s.peer, s.session, s.transport], do: {pid, Process.monitor(pid)}
      send(owner, :stop)
      for {pid, ref} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 1000)
    end

    defp relay(target) do
      receive do
        :stop ->
          :ok

        event ->
          send(target, event)
          relay(target)
      end
    end

    test "Session timeout flushes queued RTP from a blocked adapter" do
      opts = [
        speech_to_speech:
          function(fn _, emit ->
            emit.({:audio, %Audio{data: :binary.copy(<<0, 0>>, 8000), sample_rate: 8000}})
            Process.sleep(:infinity)
          end),
        timeout_ms: 100
      ]

      {peer, bridge} = pair(session: opts)
      {:ok, turn} = Session.submit(bridge, %Audio{data: <<0, 0>>, sample_rate: 16_000})
      _ = packet(peer)
      assert_receive {Session, ^bridge, {:session, ^turn, {:error, :timeout, _}}}, 1000
      s = :sys.get_state(bridge)
      assert :queue.is_empty(:sys.get_state(s.transport).queue)
      assert :sys.get_state(s.transport).key == nil
    end

    test "two peers: ingress becomes submitted PCM, transcript/text/audio route, paced PCMU matches stateful resampling" do
      {peer, bridge} = pair()
      speak(peer)
      assert_receive {Session, ^bridge, {:utterance, :silence}}, 1000
      assert_receive {:input, %Audio{data: input, sample_rate: 16_000}}, 1000

      {expected, up} =
        RateConverter.up(
          MuLaw.decode(MuLaw.encode(:binary.copy(<<0x10, 0x27>>, 160))),
          %RateConverter{}
        )

      {silence, _} = RateConverter.up(MuLaw.decode(:binary.copy(<<255>>, 160)), up)
      assert input == expected <> silence <> :binary.copy(<<0>>, 640)
      assert_receive {Session, ^bridge, {:session, turn, {:transcript, "actual utterance"}}}
      assert_receive {Session, ^bridge, {:session, ^turn, {:text, "reply text"}}}
      assert_receive {Session, ^bridge, {:session, ^turn, {:audio, %Audio{sample_rate: 16_000}}}}
      assert_receive {Session, ^bridge, {:session, ^turn, {:done, _}}}
      {pcm, down} = RateConverter.down(:binary.copy(<<0x10, 0x27>>, 1600), %RateConverter{})
      {tail, _} = RateConverter.down(:binary.copy(<<0>>, 60), down)
      expected = MuLaw.encode(pcm <> tail)
      expected = expected <> :binary.copy(<<255>>, rem(160 - rem(byte_size(expected), 160), 160))
      started = System.monotonic_time(:millisecond)
      packets = for _ <- 1..6, do: packet(peer)
      assert System.monotonic_time(:millisecond) - started >= 70
      assert Enum.map_join(packets, & &1.payload) == expected
      assert Enum.map(packets, & &1.timestamp) == Enum.to_list(0..800//160)
      assert Enum.all?(packets, &(&1.payload_type == 0))
      state = :sys.get_state(bridge)
      assert :sys.get_state(state.session).playback_history.playout.played == 0
    end

    test "cancel flushes finished turn queues and rejects stale pushes without changing next turn clocks" do
      {peer, bridge} = pair()
      s = :sys.get_state(bridge)
      key = {s.session, make_ref()}
      :ok = Transport.start_turn(s.transport, key)

      :ok =
        Transport.push(s.transport, key, %Audio{
          data: :binary.copy(<<0x10, 0x27>>, 8000),
          sample_rate: 8000
        })

      :ok = Transport.finish(s.transport, key)
      _ = packet(peer)
      {_, old_token} = :sys.get_state(s.transport).timer
      :ok = Transport.flush(s.transport, key)
      assert :queue.is_empty(:sys.get_state(s.transport).queue)

      assert {:error, :stale_turn} =
               Transport.push(s.transport, key, %Audio{data: <<0, 0>>, sample_rate: 8000})

      # A queued timer from the old generation must not send a new packet.
      send(s.transport, {:tick, old_token})
      refute_receive {WebRTC, ^peer, {:media, {:rtp, _, nil, _}}}, 100
      next = {s.session, make_ref()}
      :ok = Transport.start_turn(s.transport, next)

      :ok =
        Transport.push(s.transport, next, %Audio{
          data: :binary.copy(<<0, 0>>, 160),
          sample_rate: 8000
        })

      fresh = packet(peer)
      assert fresh.timestamp >= 160
      assert fresh.payload == :binary.copy(<<255>>, 160)
    end

    test "speech start interrupts a Session response and stale queue cannot leak after cancel" do
      {peer, bridge} = pair()
      s = :sys.get_state(bridge)
      # Make a real turn whose output stays queued long enough for barge-in.
      :sys.replace_state(s.session, fn state ->
        put_in(
          state,
          [:adapters, :tts],
          function(fn _, emit ->
            emit.(%Audio{data: :binary.copy(<<0x10, 0x27>>, 16_000), sample_rate: 16_000})
          end)
        )
      end)

      speak(peer)
      assert_receive {Session, ^bridge, {:session, _, {:done, _}}}, 1000
      _ = packet(peer)
      key = :sys.get_state(s.transport).key
      # Speech only: confirmed start cancels playback even before endpoint.
      turn = make_ref()
      :ok = WebRTC.start_turn(peer, turn)

      :ok =
        WebRTC.publish(
          peer,
          turn,
          :audio,
          MuLaw.encode(:binary.copy(<<0x10, 0x27>>, 160)),
          60_000
        )

      # Synchronize on the ingress state having consumed the third packet.
      await(fn -> :sys.get_state(bridge).expected == 4 end)
      assert :sys.get_state(s.transport).key == nil
      assert :queue.is_empty(:sys.get_state(s.transport).queue)

      assert {:error, :stale_turn} =
               Transport.push(s.transport, key, %Audio{data: <<0, 0>>, sample_rate: 8000})
    end

    defp await(fun, n \\ 100)
    defp await(_, 0), do: flunk("state deadline")

    defp await(fun, n) do
      if fun.(),
        do: :ok,
        else:
          (
            Process.sleep(5)
            await(fun, n - 1)
          )
    end

    test "bounded output rejects unsupported rates, format changes and overflow" do
      {_peer, bridge} = pair(max_queue_packets: 2)
      s = :sys.get_state(bridge)
      key = make_ref()
      :ok = Transport.start_turn(s.transport, key)

      assert {:error, :unsupported_pcm} =
               Transport.push(s.transport, key, %Audio{data: <<0, 0>>, sample_rate: 24_000})

      assert {:error, :queue_limit} =
               Transport.push(s.transport, key, %Audio{
                 data: :binary.copy(<<0, 0>>, 481),
                 sample_rate: 8000
               })

      :ok = Transport.push(s.transport, key, %Audio{data: <<0, 0>>, sample_rate: 8000})

      assert {:error, :output_format_changed} =
               Transport.push(s.transport, key, %Audio{data: <<0, 0>>, sample_rate: 16_000})
    end

    test "negotiation timeout and owner exit clean up Session, output and peer" do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, bridge} =
        Session.start_link(
          owner: owner,
          session: Demo.options(),
          vad: {Detector, []},
          negotiation_timeout_ms: 30
        )

      s = :sys.get_state(bridge)
      refs = for pid <- [bridge, s.peer, s.transport, s.session], do: {pid, Process.monitor(pid)}
      for {pid, ref} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 1000)
      send(owner, :stop)
    end
  end
end
