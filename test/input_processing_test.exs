defmodule AudioFlow.InputProcessingTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Audio
  alias AudioFlow.VoiceInput

  defmodule Turn do
    def init(opts), do: opts

    def predict(audio, opts) do
      send(opts[:owner], {:semantic_audio, audio})
      if opts[:sleep], do: Process.sleep(opts[:sleep])
      if opts[:raise], do: raise("inference failed")
      opts[:probability]
    end
  end

  defmodule SubtractReference do
    def init(_, _, _), do: nil

    def process(audio, reference, state) do
      mic = for <<x::little-signed-16 <- audio.data>>, do: x
      ref = for <<x::little-signed-16 <- reference.data>>, do: x

      pcm =
        Enum.zip_with(mic, ref, fn x, y -> <<x - y::little-signed-16>> end)
        |> IO.iodata_to_binary()

      {%{audio | data: pcm}, state}
    end
  end

  defp frame(x), do: :binary.copy(<<x::little-signed-16>>, 512)
  defp audio(pcm), do: %Audio{data: pcm, sample_rate: 16_000}

  defp input(opts) do
    VoiceInput.new(
      {AudioFlow.Test.FrameDetector, []},
      Keyword.merge(
        [
          min_speech_ms: 32,
          min_silence_ms: 32,
          pre_roll_ms: 0,
          turn_retry_ms: 32,
          max_semantic_silence_ms: 96
        ],
        opts
      )
    )
  end

  test "semantic incomplete joins resumed speech until completion or bounded silence" do
    state = input(turn_detector: {Turn, owner: self(), probability: 0.1})
    {[:speech_started], state} = VoiceInput.push(state, audio(frame(32_000) <> frame(0)))
    assert_receive {:semantic_audio, %Audio{data: pcm}}
    assert pcm == frame(32_000) <> frame(0)
    {[], state} = VoiceInput.push(state, audio(frame(32_000) <> frame(0)))

    {[{:utterance, result, :semantic_limit}], _} =
      VoiceInput.push(state, audio(frame(0) <> frame(0)))

    assert result.data == frame(32_000) <> frame(0) <> frame(32_000) <> :binary.copy(frame(0), 3)
  end

  test "semantic completion emits after VAD silence and resets per utterance" do
    state = input(turn_detector: {Turn, owner: self(), probability: 0.9})

    for _ <- 1..2, reduce: state do
      state ->
        expected = audio(frame(32_000) <> frame(0))

        assert {[:speech_started, {:utterance, ^expected, :semantic}], state} =
                 VoiceInput.push(state, expected)

        assert_receive {:semantic_audio, ^expected}
        state
    end
  end

  test "slow and failed models fall back to silence without losing audio" do
    for opts <- [[sleep: 1000], [raise: true], [probability: 2.0]] do
      state = input(turn_detector: {Turn, [owner: self()] ++ opts}, turn_timeout_ms: 10)
      before = System.monotonic_time(:millisecond)

      assert {[:speech_started, {:utterance, _, :semantic_fallback}], _} =
               VoiceInput.push(state, audio(frame(32_000) <> frame(0)))

      assert System.monotonic_time(:millisecond) - before < 500
    end
  end

  test "hard utterance limit and EOS override an incomplete model" do
    state = input(turn_detector: {Turn, owner: self(), probability: 0.1}, max_utterance_ms: 64)

    assert {[:speech_started, {:utterance, _, :limit}], _} =
             VoiceInput.push(state, audio(frame(32_000) <> frame(0)))

    {[:speech_started], state} = VoiceInput.push(state, audio(frame(32_000)))
    assert {[{:utterance, _, :end_of_stream}], _} = VoiceInput.flush(state)
  end

  test "preprocessing precedes VAD and preserves alignment across chunk and utterance boundaries" do
    state = input(preprocessor: {SubtractReference, []})
    pcm = frame(32_000) <> frame(32_000) <> frame(32_000) <> frame(0)
    ref = frame(32_000) <> frame(0) <> frame(32_000) <> frame(0)
    <<a::binary-size(300), b::binary>> = pcm
    <<ra::binary-size(300), rb::binary>> = ref
    {[], state} = VoiceInput.push(state, audio(a), audio(ra))
    {events, state} = VoiceInput.push(state, audio(b), audio(rb))
    assert events == [:speech_started, {:utterance, audio(frame(32_000) <> frame(0)), :silence}]
    assert {[], _} = VoiceInput.flush(state)
    assert_raise ArgumentError, fn -> VoiceInput.push(state, audio(pcm), audio(<<>>)) end
  end

  test "a semantic check receives only the last eight seconds of a long utterance" do
    state = input(turn_detector: {Turn, owner: self(), probability: 0.9})
    pcm = :binary.copy(frame(32_000), 600) <> frame(0)

    assert {[:speech_started, {:utterance, _, :semantic}], _} = VoiceInput.push(state, audio(pcm))
    assert_receive {:semantic_audio, %Audio{data: tail}}
    assert tail == binary_part(pcm, byte_size(pcm) - 256_000, 256_000)
  end

  test "references are not queued when there is no preprocessor" do
    state = input([])
    {[:speech_started], state} = VoiceInput.push(state, audio(frame(32_000)))
    assert state.reference_pending == <<>>

    {[], state} = VoiceInput.push(state, audio(frame(32_000)), audio(frame(0)))
    assert state.reference_pending == <<>>
    assert {[{:utterance, utterance, :end_of_stream}], _} = VoiceInput.flush(state)
    assert utterance.data == frame(32_000) <> frame(32_000)
  end

  describe "async semantic checks" do
    defp async_input(opts), do: input([async_turn: true] ++ opts)

    test "push returns while the model runs and the result ends the utterance with all frames" do
      state = async_input(turn_detector: {Turn, owner: self(), probability: 0.9, sleep: 100})
      before = System.monotonic_time(:millisecond)

      assert {[:speech_started], state} =
               VoiceInput.push(state, audio(frame(32_000) <> frame(0)))

      assert System.monotonic_time(:millisecond) - before < 80
      assert {[], state} = VoiceInput.push(state, audio(frame(0)))

      assert_receive {:audio_flow_turn, _, _} = message, 1000

      assert {:ok, [{:utterance, utterance, :semantic}], state} =
               VoiceInput.handle_info(state, message)

      assert utterance.data == frame(32_000) <> frame(0) <> frame(0)
      assert state.turn == nil
      assert {[:speech_started], _} = VoiceInput.push(state, audio(frame(32_000)))
    end

    test "an incomplete turn keeps the utterance open" do
      state = async_input(turn_detector: {Turn, owner: self(), probability: 0.1})
      {[:speech_started], state} = VoiceInput.push(state, audio(frame(32_000) <> frame(0)))
      assert_receive {:audio_flow_turn, _, _} = message, 1000
      assert {:ok, [], state} = VoiceInput.handle_info(state, message)
      assert {[{:utterance, _, :end_of_stream}], _} = VoiceInput.flush(state)
    end

    test "a slow or failed model resolves as a fallback" do
      for opts <- [[sleep: 1000], [raise: true], [probability: 2.0]] do
        state =
          async_input(turn_detector: {Turn, [owner: self()] ++ opts}, turn_timeout_ms: 20)

        {[:speech_started], state} = VoiceInput.push(state, audio(frame(32_000) <> frame(0)))

        message =
          receive do
            {:audio_flow_turn, _, _} = message -> message
            {:audio_flow_turn_timeout, _} = message -> message
          after
            1000 -> flunk("no turn message")
          end

        assert {:ok, [{:utterance, _, :semantic_fallback}], %{turn: nil}} =
                 VoiceInput.handle_info(state, message)
      end
    end

    test "resumed speech drops the pending check" do
      state = async_input(turn_detector: {Turn, owner: self(), probability: 0.9, sleep: 50})
      {[:speech_started], state} = VoiceInput.push(state, audio(frame(32_000) <> frame(0)))
      assert state.turn
      {[], state} = VoiceInput.push(state, audio(frame(32_000)))
      assert state.turn == nil
      refute_receive {:audio_flow_turn, _, _}, 150
      refute_receive {:audio_flow_turn_timeout, _}, 50
    end

    test "a hard limit ends the utterance and drops the pending check" do
      state =
        async_input(
          turn_detector: {Turn, owner: self(), probability: 0.9, sleep: 50},
          max_utterance_ms: 96
        )

      {[:speech_started], state} = VoiceInput.push(state, audio(frame(32_000) <> frame(0)))
      assert {[{:utterance, utterance, :limit}], state} = VoiceInput.push(state, audio(frame(0)))
      assert byte_size(utterance.data) == 3 * 1024
      assert state.turn == nil
      refute_receive {:audio_flow_turn, _, _}, 150
    end

    test "handle_info ignores stale turn messages and rejects other messages" do
      state = async_input(turn_detector: {Turn, owner: self(), probability: 0.9})
      assert :unknown = VoiceInput.handle_info(state, :other)

      assert {:ok, [], ^state} =
               VoiceInput.handle_info(state, {:audio_flow_turn, make_ref(), 0.9})

      assert {:ok, [], ^state} =
               VoiceInput.handle_info(state, {:audio_flow_turn_timeout, make_ref()})
    end
  end
end
