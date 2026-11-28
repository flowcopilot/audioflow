defmodule AudioFlow.VoiceInput.OptionsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Test.FrameDetector
  alias AudioFlow.Transport.Connection
  alias AudioFlow.VoiceInput.Options

  test ":voice_input is read as it is, and the defaults fill the gaps" do
    assert Options.fetch([voice_input: [min_speech_ms: 32]], async_turn: true) ==
             [async_turn: true, min_speech_ms: 32]

    assert Options.fetch([voice_input: [async_turn: false]], async_turn: true) ==
             [async_turn: false]

    assert Options.fetch([]) == []
  end

  test "the deprecated :endpoint_options works and logs one warning" do
    log =
      capture_log(fn ->
        assert Options.fetch([endpoint_options: [min_speech_ms: 32]], async_turn: true) ==
                 [async_turn: true, min_speech_ms: 32]
      end)

    assert [_] = Regex.scan(~r/\[warning\]/, log)
    assert log =~ ":endpoint_options option is deprecated, use :voice_input"
  end

  test ":voice_input wins when both are given" do
    log =
      capture_log(fn ->
        assert Options.fetch(
                 voice_input: [min_speech_ms: 32],
                 endpoint_options: [min_speech_ms: 64]
               ) ==
                 [min_speech_ms: 32]
      end)

    assert log =~ "deprecated"
  end

  test "a transport still starts with the deprecated name" do
    log =
      capture_log(fn ->
        {:events, _ready, state} =
          Connection.init(
            session: Demo.options(),
            vad: {FrameDetector, []},
            endpoint_options: [min_speech_ms: 32, pre_roll_ms: 0]
          )

        on_exit(fn -> Connection.terminate(:normal, state) end)
        assert state.input.limits.speech == 1
      end)

    assert log =~ "endpoint_options"
  end
end
