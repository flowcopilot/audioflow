defmodule AudioFlow.AsyncTurnTransportTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Test.GatedTurn
  alias AudioFlow.Transport.Connection

  # A pending check holds the turn detector for as long as the test wants. A
  # blocking check would hold the transport process for `turn_timeout_ms`.
  @voice_input [
    min_speech_ms: 32,
    min_silence_ms: 32,
    pre_roll_ms: 0,
    turn_timeout_ms: 5000
  ]

  defp frame(x), do: :binary.copy(<<x::little-signed-16>>, 512)

  defp voice_input(extra \\ []),
    do: Keyword.merge([turn_detector: {GatedTurn, owner: self()}] ++ @voice_input, extra)

  # Runs `fun` and fails when it takes long, which a blocking check would cause.
  defp quick(fun) do
    {microseconds, result} = :timer.tc(fun)
    assert microseconds < 1_000_000, "the transport blocked for #{div(microseconds, 1000)} ms"
    result
  end

  defp events({:push, frames, state}),
    do: {for({:text, json} <- frames, do: JSON.decode!(json)), state}

  defp events({:ok, state}), do: {[], state}

  describe "AudioFlow.WebSocket" do
    setup do
      options = [
        session: Demo.options(),
        vad: {AudioFlow.Test.FrameDetector, []},
        voice_input: voice_input()
      ]

      {:push, [{:text, ready}], state} = AudioFlow.WebSocket.init(options)
      assert %{"type" => "ready", "mode" => "vad"} = JSON.decode!(ready)
      on_exit(fn -> AudioFlow.WebSocket.terminate(:normal, state) end)
      %{state: state}
    end

    test "keeps handling input while a check is pending, then submits the utterance", %{
      state: state
    } do
      {events, state} =
        quick(fn ->
          events(
            AudioFlow.WebSocket.handle_in({frame(32_000) <> frame(0), opcode: :binary}, state)
          )
        end)

      assert [%{"type" => "speech_started"}] = events
      assert_receive {:turn_gate, gate, _audio}

      # More frames and commands are processed while the detector still works.
      {[], state} =
        quick(fn -> events(AudioFlow.WebSocket.handle_in({frame(0), opcode: :binary}, state)) end)

      {[%{"type" => "error", "reason" => "invalid_message"}], state} =
        quick(fn ->
          events(AudioFlow.WebSocket.handle_in({~s({"type":"dance"}), opcode: :text}, state))
        end)

      refute_received {:audio_flow_turn, _, _}
      send(gate, :release)
      assert_receive {:audio_flow_turn, _, _} = message

      {events, state} = events(AudioFlow.WebSocket.handle_info(message, state))
      assert [%{"type" => "turn_started", "turn" => 1}] = events
      assert state.turn
    end

    test "a user can turn the default off", %{state: _state} do
      options = [
        session: Demo.options(),
        vad: {AudioFlow.Test.FrameDetector, []},
        voice_input: voice_input(async_turn: false, turn_timeout_ms: 50)
      ]

      {:push, _ready, state} = AudioFlow.WebSocket.init(options)
      on_exit(fn -> AudioFlow.WebSocket.terminate(:normal, state) end)

      # The check blocks this call until the detector times out.
      {events, _state} =
        events(AudioFlow.WebSocket.handle_in({frame(32_000) <> frame(0), opcode: :binary}, state))

      assert [%{"type" => "speech_started"}, %{"type" => "turn_started"}] = events
    end
  end

  describe "AudioFlow.Telephony.WebSocket" do
    defp media(chunk, bytes),
      do:
        JSON.encode!(%{
          event: "media",
          streamSid: "stream-1",
          media: %{track: "inbound", chunk: "#{chunk}", payload: Base.encode64(bytes)}
        })

    test "keeps handling media while a check is pending, then submits the utterance" do
      {:ok, state} =
        AudioFlow.Telephony.WebSocket.init(
          provider: :twilio,
          session: Demo.options(),
          vad: {AudioFlow.Test.AmplitudeDetector, []},
          voice_input: voice_input(min_speech_ms: 20, min_silence_ms: 20)
        )

      on_exit(fn -> AudioFlow.Telephony.WebSocket.terminate(:normal, state) end)
      handler = AudioFlow.Telephony.WebSocket

      start = %{
        event: "start",
        streamSid: "stream-1",
        start: %{
          streamSid: "stream-1",
          mediaFormat: %{encoding: "audio/x-mulaw", sampleRate: 8000, channels: 1}
        }
      }

      {:ok, state} =
        handler.handle_in({JSON.encode!(%{event: "connected"}), opcode: :text}, state)

      {_, state} = events(handler.handle_in({JSON.encode!(start), opcode: :text}, state))

      loud = :binary.copy(<<156>>, 160)
      quiet = :binary.copy(<<255>>, 160)

      {_, state} =
        quick(fn ->
          events(
            handler.handle_in({media(1, loud <> :binary.copy(quiet, 5)), opcode: :text}, state)
          )
        end)

      assert_receive {:turn_gate, gate, _audio}

      {_, state} =
        quick(fn ->
          events(handler.handle_in({media(2, quiet <> quiet), opcode: :text}, state))
        end)

      refute_received {:audio_flow_turn, _, _}
      assert state.pcm.turn == nil
      send(gate, :release)
      assert_receive {:audio_flow_turn, _, _} = message

      {_, state} = events(handler.handle_info(message, state))
      assert {_ref, 1} = state.pcm.turn
    end
  end

  describe "Connection" do
    test "an unrelated message and a stale check message change nothing" do
      {:events, _ready, state} =
        Connection.init(
          session: Demo.options(),
          vad: {AudioFlow.Test.FrameDetector, []},
          voice_input: voice_input()
        )

      on_exit(fn -> Connection.terminate(:normal, state) end)

      assert {:ok, ^state} = Connection.handle_info(:something_else, state)
      assert {:ok, ^state} = Connection.handle_info({:audio_flow_turn, make_ref(), 0.9}, state)
      assert {:ok, ^state} = Connection.handle_info({:audio_flow_turn_timeout, make_ref()}, state)
    end
  end
end
