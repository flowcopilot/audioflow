defmodule AudioFlow.VoiceInputTest do
  use ExUnit.Case, async: true
  alias AudioFlow.{Audio, VoiceInput}

  defp frame(value), do: :binary.copy(<<value::little-signed-16>>, 512)
  defp audio(data), do: %Audio{data: data, sample_rate: 16_000}
  defp input(options \\ []), do: VoiceInput.new({AudioFlow.Test.FrameDetector, []}, options)

  test "speech confirmation keeps pre-roll, preserves uncertain speech, and waits for silence" do
    silence = frame(0)
    speech = frame(32000)
    uncertain = frame(16000)
    state = input(min_silence_ms: 64)
    {[], state} = VoiceInput.push(state, audio(silence <> speech <> speech))
    {[:speech_started], state} = VoiceInput.push(state, audio(speech <> uncertain <> silence))
    {[{:utterance, result, :silence}], state} = VoiceInput.push(state, audio(silence))

    assert result ==
             audio(silence <> speech <> speech <> speech <> uncertain <> silence <> silence)

    assert {[], _} = VoiceInput.flush(state)
  end

  test "a short sound is rejected and input frame splits do not lose samples" do
    speech = frame(32000)
    silence = frame(0)
    data = speech <> silence <> speech <> speech <> speech <> silence <> silence
    <<first::binary-size(300), rest::binary>> = data
    {[], state} = VoiceInput.push(input(min_silence_ms: 64, pre_roll_ms: 0), audio(first))
    {events, _} = VoiceInput.push(state, audio(rest))

    assert events == [
             :speech_started,
             {:utterance, audio(speech <> speech <> speech <> silence <> silence), :silence}
           ]
  end

  test "maximum duration splits continuous speech into bounded utterances" do
    data = :binary.copy(frame(32000), 6)

    {events, _} =
      VoiceInput.push(
        input(min_speech_ms: 32, pre_roll_ms: 0, max_utterance_ms: 100),
        audio(data)
      )

    expected = {:utterance, audio(:binary.copy(frame(32000), 3)), :limit}
    assert events == [:speech_started, expected, :speech_started, expected]
  end

  test "end of stream keeps a partial frame and ends confirmed speech" do
    {[:speech_started], state} =
      VoiceInput.push(input(pre_roll_ms: 0), audio(:binary.copy(frame(32000), 3) <> <<0, 0>>))

    {[{:utterance, result, :end_of_stream}], _} = VoiceInput.flush(state)
    assert result == audio(:binary.copy(frame(32000), 3) <> frame(0))
  end

  test "invalid format and limits fail before PCM is processed" do
    assert_raise ArgumentError, fn ->
      VoiceInput.push(input(), %Audio{data: <<0>>, sample_rate: 16000})
    end

    assert_raise ArgumentError, fn ->
      VoiceInput.push(input(), %Audio{data: <<0, 0>>, sample_rate: 8000})
    end

    for options <- [
          [threshold: 1.1],
          [silence_threshold: 0.6],
          [min_speech_ms: 0],
          [max_utterance_ms: 32]
        ] do
      assert_raise ArgumentError, fn -> input(options) end
    end
  end
end
