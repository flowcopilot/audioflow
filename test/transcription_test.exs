defmodule AudioFlow.TranscriptionTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Audio
  alias AudioFlow.Text
  alias AudioFlow.Transcript
  alias AudioFlow.Transcript.Segment
  alias AudioFlow.Wav

  defp function(fun), do: {AudioFlow.Adapters.Function, [run: fun]}

  defp start(options) do
    {:ok, session} = AudioFlow.start_session(options)
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    session
  end

  # 16 kHz PCM where each sample holds its own millisecond offset.
  defp timeline(ms) do
    data = for i <- 0..(ms * 16 - 1), into: <<>>, do: <<div(i, 16)::little-signed-16>>
    %Audio{data: data, sample_rate: 16_000}
  end

  defp first_ms(%Audio{data: <<ms::little-signed-16, _::binary>>}), do: ms

  describe "transcription session" do
    test "ends the turn after STT, with segments and partials as events" do
      owner = self()

      stt =
        function(fn _audio, emit ->
          emit.({:partial, "hel"})
          emit.(%Segment{text: "hello", start_ms: 0, end_ms: 400})
          emit.({:partial, "wor"})
          emit.(%Segment{text: " world ", start_ms: 400, end_ms: 900})
        end)

      session = start(stt: stt, owner: owner)
      {:ok, turn} = AudioFlow.submit(session, %Audio{data: <<0, 0>>, sample_rate: 16_000})

      assert_receive {AudioFlow, ^session, ^turn, {:partial_transcript, "hel"}}
      assert_receive {AudioFlow, ^session, ^turn, {:segment, %Segment{text: "hello"}}}
      assert_receive {AudioFlow, ^session, ^turn, {:partial_transcript, "wor"}}
      assert_receive {AudioFlow, ^session, ^turn, {:segment, %Segment{start_ms: 400}}}
      assert_receive {AudioFlow, ^session, ^turn, {:done, metrics}}
      assert metrics.events == 4
      assert metrics.first_partial_transcript_us <= metrics.first_transcript_us
      assert metrics.first_text_us == nil
    end

    test "rejects text input, history, and only one of :llm and :tts" do
      stt = function(fn _, emit -> emit.("hi") end)
      session = start(stt: stt)
      assert {:error, {:unsupported_input, :llm}} = AudioFlow.submit(session, %Text{data: "hi"})

      Process.flag(:trap_exit, true)
      assert {:error, _} = AudioFlow.start_session(stt: stt, history: true)
      assert {:error, _} = AudioFlow.start_session(stt: stt, llm: stt)
    end

    test "invalid segments fail the turn" do
      stt = function(fn _, emit -> emit.(%Segment{text: "x", start_ms: 5, end_ms: 1}) end)
      session = start(stt: stt)
      {:ok, turn} = AudioFlow.submit(session, %Audio{data: <<0, 0>>, sample_rate: 16_000})
      assert_receive {AudioFlow, ^session, ^turn, {:error, :invalid_output, _}}
    end
  end

  test "segment text forms the LLM prompt; partials are excluded" do
    owner = self()

    stt =
      function(fn _, emit ->
        emit.({:partial, "Hel"})
        emit.(%Segment{text: "Hello"})
        emit.(%Segment{text: "world"})
      end)

    llm =
      function(fn prompt, _emit ->
        send(owner, {:prompt, prompt})
        :ok
      end)

    tts = function(fn _, _ -> :ok end)
    session = start(stt: stt, llm: llm, tts: tts)
    {:ok, turn} = AudioFlow.submit(session, %Audio{data: <<0, 0>>, sample_rate: 16_000})
    assert_receive {:prompt, "Hello world"}
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
  end

  describe "batch transcription" do
    test "fixed windows give ordered segments with input offsets" do
      owner = self()

      stt =
        function(fn audio, emit ->
          send(owner, {:section, first_ms(audio), byte_size(audio.data)})
          emit.("part #{first_ms(audio)}")
        end)

      assert {:ok, transcript} =
               AudioFlow.transcribe(timeline(2500), stt,
                 chunk_ms: 1000,
                 max_concurrency: 3,
                 on_segment: &send(owner, {:segment, &1.start_ms})
               )

      assert transcript.text == "part 0 part 1000 part 2000"

      assert Enum.map(transcript.segments, &{&1.start_ms, &1.end_ms}) ==
               [{0, 1000}, {1000, 2000}, {2000, 2500}]

      assert_receive {:section, 2000, 16_000}

      for start <- [0, 1000, 2000],
          do: assert_receive({:segment, ^start})
    end

    test "adapter segment times are shifted by the section start" do
      stt =
        function(fn audio, emit ->
          emit.(%Segment{
            text: " w ",
            start_ms: 100,
            end_ms: 200,
            words: [%{word: "w", start_ms: 100, end_ms: 200}]
          })

          if first_ms(audio) == 1000, do: emit.(%Segment{text: "untimed"})
          :ok
        end)

      {:ok, transcript} = AudioFlow.transcribe(timeline(2000), stt, chunk_ms: 1000)

      assert [
               %Segment{text: "w", start_ms: 100, end_ms: 200},
               %Segment{text: "w", start_ms: 1100, words: [%{start_ms: 1100, end_ms: 1200}]},
               %Segment{text: "untimed", start_ms: 1000, end_ms: 2000}
             ] = transcript.segments
    end

    test "voice detection sends only utterances, at their input offsets" do
      owner = self()
      frame = fn level, count -> :binary.copy(<<level::little-signed-16>>, 512 * count) end
      # 32 ms frames: 10 silent, 10 speech, 20 silent, 10 speech, 10 silent.
      data =
        frame.(0, 10) <>
          frame.(32_000, 10) <> frame.(0, 20) <> frame.(32_000, 10) <> frame.(0, 10)

      stt =
        function(fn audio, emit ->
          send(owner, {:utterance, byte_size(audio.data)})
          emit.("speech")
        end)

      {:ok, transcript} =
        AudioFlow.transcribe(%Audio{data: data, sample_rate: 16_000}, stt,
          vad: {AudioFlow.Test.FrameDetector, []},
          endpoint_options: [pre_roll_ms: 0, min_speech_ms: 32, min_silence_ms: 320]
        )

      assert transcript.text == "speech speech"
      assert [first, second] = transcript.segments
      assert first.start_ms == 320
      assert second.start_ms == 1280
      assert first.end_ms > 640 and second.end_ms > 1600
    end

    test "the first failing section stops the work" do
      stt =
        function(fn audio, emit ->
          if first_ms(audio) == 1000, do: {:error, :quota}, else: emit.("ok")
        end)

      assert {:error, {:section, 1, :quota}} =
               AudioFlow.transcribe(timeline(3000), stt, chunk_ms: 1000)

      slow = function(fn _, _ -> Process.sleep(1000) end)

      assert {:error, {:section, 0, :timeout}} =
               AudioFlow.transcribe(timeline(100), slow, timeout_ms: 20)

      bad = function(fn _, emit -> emit.(:nope) end)
      assert {:error, {:section, 0, :invalid_output}} = AudioFlow.transcribe(timeline(100), bad)
    end
  end

  test "WAV round trip and captions" do
    audio = %Audio{data: <<1, 0, 2, 0, 3, 0>>, sample_rate: 22_050}
    assert {:ok, ^audio} = audio |> Wav.encode() |> Wav.decode()

    stereo =
      <<"RIFF", 0::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 2::little-16,
        8000::little-32, 32_000::little-32, 4::little-16, 16::little-16, "data", 0::little-32>>

    assert {:error, :unsupported_wav} = Wav.decode(stereo)
    assert {:error, :invalid_wav} = Wav.decode("not a wav")

    transcript =
      Transcript.new([
        %Segment{text: "Hello.", start_ms: 0, end_ms: 1500},
        %Segment{text: "", start_ms: 1500, end_ms: 1600},
        %Segment{text: "Bye.", start_ms: 3_661_001, end_ms: 3_662_000}
      ])

    assert transcript.text == "Hello. Bye."

    assert Transcript.to_srt(transcript) ==
             "1\n00:00:00,000 --> 00:00:01,500\nHello.\n\n" <>
               "2\n01:01:01,001 --> 01:01:02,000\nBye.\n"

    assert Transcript.to_vtt(transcript) ==
             "WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nHello.\n\n" <>
               "01:01:01.001 --> 01:01:02.000\nBye.\n"

    assert_raise ArgumentError, fn -> Transcript.to_srt(Transcript.new([%Segment{text: "x"}])) end
  end
end
