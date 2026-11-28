if System.get_env("AUDIOFLOW_SFU") == "1" do
  defmodule AudioFlow.SFUParticipantTest do
    use ExUnit.Case, async: false
    alias AudioFlow.Audio
    alias AudioFlow.SFU.Participant
    alias AudioFlow.SFU.Transport
    alias Membrane.Opus.Decoder.Native, as: Decoder
    alias Membrane.Opus.Encoder.Native, as: Encoder

    defmodule Detector do
      def init(_), do: {320, 16_000, nil}

      def predict(%Audio{data: data}, state) do
        speech = for(<<x::little-signed-16 <- data>>, do: abs(x)) |> Enum.max()
        {if(speech > 1000, do: 1.0, else: 0.0), state}
      end
    end

    @user %{
      sid: "PA_user",
      identity: "user",
      kind: :standard,
      joined_at: 1,
      tracks: [%{sid: "TR_user", mime_type: "audio/opus", name: "microphone"}]
    }

    defp function(fun), do: {AudioFlow.Adapters.Function, run: fun}

    defp start(join \\ [], options \\ []) do
      test = self()

      session = [
        stt:
          function(fn audio, emit ->
            send(test, {:heard, audio})
            emit.("hello")
          end),
        llm: function(fn "hello", emit -> emit.("reply") end),
        tts:
          function(fn "reply", emit ->
            emit.(%Audio{data: :binary.copy(<<0x10, 0x27>>, 8000), sample_rate: 16_000})
          end)
      ]

      {:ok, agent} =
        Participant.start_link(
          Keyword.merge(
            [
              room: "room",
              identity: "agent",
              session: session,
              vad: {Detector, []},
              voice_input: [min_speech_ms: 20, min_silence_ms: 60, pre_roll_ms: 0],
              gap_timeout_ms: 50,
              join: Keyword.merge([test: test, others: [@user]], join)
            ],
            options
          )
        )

      assert_receive {:sfu_join, participant, ^agent, _}
      assert_receive {Participant, ^agent, {:joined, _}}
      {agent, participant}
    end

    # 20 ms Opus frames at 48 kHz: a loud tone, then silence.
    defp opus_frames(loud, quiet) do
      encoder = Encoder.create(48_000, 1, 2048, -1000, 3001)

      tone =
        for i <- 0..959,
            into: <<>>,
            do: <<round(:math.sin(i / 960 * 2 * :math.pi() * 20) * 12_000)::little-signed-16>>

      silence = :binary.copy(<<0, 0>>, 960)

      for pcm <- List.duplicate(tone, loud) ++ List.duplicate(silence, quiet) do
        {:ok, packet} = Encoder.encode_packet(encoder, pcm, 960)
        packet
      end
    end

    defp rtp(sequence, payload, timestamp \\ nil),
      do: %{
        sequence_number: sequence,
        timestamp: timestamp || sequence * 960,
        marker: false,
        payload: payload
      }

    defp send_user(agent, participant, frames, skip \\ []) do
      frames
      |> Enum.with_index(100)
      |> Enum.reject(fn {_, seq} -> seq in skip end)
      |> Enum.each(fn {payload, seq} ->
        send(agent, {:audio_flow_sfu, 1, participant, {:rtp, "TR_user", rtp(seq, payload)}})
      end)
    end

    test "a user utterance in the room gets a spoken Opus reply on the agent track" do
      {agent, participant} = start()
      send_user(agent, participant, opus_frames(10, 10))

      assert_receive {:heard, %Audio{sample_rate: 16_000}}, 2000
      assert_receive {Participant, ^agent, {:utterance, _}}

      # The reply: 500 ms of PCM becomes 25 paced Opus packets on the agent track.
      packets =
        for _ <- 1..25 do
          assert_receive {:sfu_participant, ^participant,
                          {:audio_flow_sfu, 1, {:rtp, "TR_agent", rtp}}},
                         2000

          rtp
        end

      sequences = Enum.map(packets, & &1.sequence_number)
      assert sequences == Enum.map(0..24, &rem(hd(sequences) + &1, 65_536))
      assert hd(packets).marker and not Enum.any?(tl(packets), & &1.marker)
      decoder = Decoder.create(48_000, 1)
      assert byte_size(Decoder.decode_packet(decoder, hd(packets).payload)) == 1920
      assert_receive {Participant, ^agent, {:session, _, {:done, _}}}, 2000
    end

    test "a pending semantic turn check does not block the participant" do
      {agent, participant} =
        start([],
          voice_input: [
            min_speech_ms: 20,
            min_silence_ms: 60,
            pre_roll_ms: 0,
            turn_timeout_ms: 5000,
            turn_detector: {AudioFlow.Test.GatedTurn, owner: self()}
          ]
        )

      send_user(agent, participant, opus_frames(10, 10))
      assert_receive {:turn_gate, gate, _audio}, 2000

      # The participant keeps taking packets while the detector works.
      assert :sys.get_state(agent, 500).input.voice.turn
      refute_received {:heard, _}
      refute_received {Participant, ^agent, {:utterance, _}}

      send(gate, :release)
      assert_receive {:heard, %Audio{sample_rate: 16_000}}, 2000
      assert_receive {Participant, ^agent, {:utterance, :semantic}}
      assert :sys.get_state(agent).input.voice.turn == nil
    end

    test "stereo Opus packets, as browsers send with stereo=1, are mixed down" do
      {agent, participant} = start()
      encoder = Encoder.create(48_000, 2, 2048, -1000, 3001)

      tone =
        for i <- 0..959,
            into: <<>>,
            do:
              <<round(:math.sin(i / 48 * :math.pi()) * 12_000)::little-signed-16>>
              |> :binary.copy(2)

      frames =
        for pcm <- List.duplicate(tone, 10) ++ List.duplicate(<<0::30_720>>, 10) do
          {:ok, packet} = Encoder.encode_packet(encoder, pcm, 960)
          packet
        end

      send_user(agent, participant, frames)
      assert_receive {:heard, %Audio{sample_rate: 16_000}}, 2000
    end

    test "a lost packet becomes silence after the gap timeout and the call goes on" do
      {agent, participant} = start()
      send_user(agent, participant, opus_frames(10, 10), [104])
      assert_receive {:heard, %Audio{}}, 2000
      assert Process.alive?(agent)
    end

    test "48 kHz TTS audio finishes its turn without a resampler" do
      {:ok, transport} = Transport.start_link(participant: self(), track: "TR_agent")
      key = {self(), make_ref()}
      :ok = Transport.start_turn(transport, key)
      pcm = :binary.copy(<<0x10, 0x27>>, 960 * 3)
      :ok = Transport.push(transport, key, %Audio{data: pcm, sample_rate: 48_000})
      assert :ok = Transport.finish(transport, key)

      for _ <- 1..3, do: assert_receive({:audio_flow_sfu, 1, {:rtp, "TR_agent", _}}, 1000)
      assert Process.alive?(transport)
    end

    test "a burst loss beyond the reorder window becomes silence and the call goes on" do
      {agent, participant} = start()
      frames = opus_frames(10, 10)
      send_user(agent, participant, Enum.take(frames, 12))

      # 288 packets are gone. The next one is far beyond the window of 32.
      send(
        agent,
        {:audio_flow_sfu, 1, participant, {:rtp, "TR_user", rtp(400, Enum.at(frames, 12))}}
      )

      assert_receive {:heard, %Audio{sample_rate: 16_000}}, 2000
      assert Process.alive?(agent)
    end

    test "packets that Opus DTX leaves out become silence from the RTP timestamps" do
      {agent, participant} = start()
      frames = opus_frames(10, 10)
      send_user(agent, participant, Enum.take(frames, 11))

      # The next sequence number, 400 ms later. 20 ms of silence alone is too
      # short for the VAD to end the utterance.
      next = rtp(111, Enum.at(frames, 11), 131 * 960)
      send(agent, {:audio_flow_sfu, 1, participant, {:rtp, "TR_user", next}})

      assert_receive {:heard, %Audio{sample_rate: 16_000}}, 2000
    end

    test "a member update keeps the stream state of the same track" do
      {agent, participant} = start()
      {loud, _} = Enum.split(opus_frames(10, 10), 5)
      send_user(agent, participant, loud)
      before = :sys.get_state(agent)
      assert before.input.reorder.expected == 105

      muted = %{@user | tracks: [Map.put(hd(@user.tracks), :muted, true)]}
      send(agent, {:audio_flow_sfu, 1, participant, {:participant_updated, muted}})

      after_update = :sys.get_state(agent)
      assert after_update.input.reorder == before.input.reorder
      assert after_update.input.codec == before.input.codec
      assert after_update.source.muted
    end

    defp output(options \\ []) do
      {:ok, transport} =
        Transport.start_link([participant: self(), track: "TR_agent"] ++ options)

      key = {self(), make_ref()}
      :ok = Transport.start_turn(transport, key)
      {transport, key}
    end

    defp frames(count),
      do: %Audio{data: :binary.copy(<<0x10, 0x27>>, 960 * count), sample_rate: 48_000}

    defp packets(count) do
      for _ <- 1..count do
        assert_receive {:audio_flow_sfu, 1, {:rtp, "TR_agent", rtp}}, 1000
        rtp
      end
    end

    test "output packets leave on absolute 20 ms deadlines" do
      {transport, key} = output()
      deadline = System.monotonic_time(:millisecond) + 50
      :sys.replace_state(transport, &%{&1 | next_at: deadline})
      :ok = Transport.push(transport, key, frames(10))
      packets(10)

      # Each tick moves the deadline by exactly 20 ms, whatever its own delay.
      assert :sys.get_state(transport).next_at == deadline + 200
    end

    test "a talkspurt after silence skips the idle time and sets the marker" do
      {transport, key} = output()
      :ok = Transport.push(transport, key, frames(3))
      first = packets(3)
      Process.sleep(300)
      :ok = Transport.push(transport, key, frames(3))
      second = packets(3)

      assert Enum.map(first, & &1.marker) == [true, false, false]
      assert Enum.map(second, & &1.marker) == [true, false, false]
      last = List.last(first)
      idle = rem(hd(second).timestamp - last.timestamp - 960 + 4_294_967_296, 4_294_967_296)
      assert idle in (250 * 48)..(400 * 48)
      assert hd(second).sequence_number == rem(last.sequence_number + 1, 65_536)
    end

    test "a push into a full queue waits for the queue to drain" do
      {transport, key} = output(max_queue_packets: 5)
      :ok = Transport.push(transport, key, frames(5))
      push = Task.async(fn -> Transport.push(transport, key, frames(3)) end)

      assert Task.yield(push, 10) == nil
      assert Task.await(push) == :ok
      assert :queue.len(:sys.get_state(transport).queue) <= 5
      packets(8)
    end

    test "a push of more than the queue limit is accepted into an empty queue" do
      {transport, key} = output(max_queue_packets: 5)
      assert :ok = Transport.push(transport, key, frames(8))
      packets(8)
    end

    test "flush releases a waiting push and finish does not wait" do
      {transport, key} = output(max_queue_packets: 5)
      :ok = Transport.push(transport, key, frames(5))
      push = Task.async(fn -> Transport.push(transport, key, frames(3)) end)
      assert Task.yield(push, 10) == nil
      assert :ok = Transport.flush(transport, key)
      assert Task.await(push) == {:error, :stale_turn}

      key = {self(), make_ref()}
      :ok = Transport.start_turn(transport, key)
      :ok = Transport.push(transport, key, frames(5))
      assert :ok = Transport.finish(transport, key)
    end

    test "agent members are not used as the audio source" do
      other_agent = %{@user | sid: "PA_bot", identity: "bot", kind: :agent, joined_at: 0}
      {agent, participant} = start(others: [other_agent, @user])
      send(agent, {:audio_flow_sfu, 1, participant, {:participant_left, @user}})
      assert_receive {Participant, ^agent, {:participant_left, %{sid: "PA_user"}}}
      send_user(agent, participant, opus_frames(10, 10))
      refute_receive {:heard, _}, 300
    end

    test "a resumed participant keeps its track and closes when the SFU says so" do
      {agent, participant} = start(tracks: [%{sid: "TR_kept", mime_type: "audio/opus"}])

      assert Participant.join_info(agent).info.tracks == [
               %{sid: "TR_kept", mime_type: "audio/opus"}
             ]

      ref = Process.monitor(agent)
      send(agent, {:audio_flow_sfu, 1, participant, {:closed, :away_timeout}})
      assert_receive {Participant, ^agent, {:closed, :away_timeout}}
      assert_receive {:DOWN, ^ref, :process, ^agent, :normal}
    end
  end
end
