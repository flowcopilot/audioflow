defmodule AudioFlow.Transport.RtpInputTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Audio
  alias AudioFlow.Transport.PCMUDecoder
  alias AudioFlow.Transport.RtpInput

  defmodule Detector do
    def init(_), do: {320, 16_000, nil}
    def predict(%Audio{}, state), do: {0.0, state}
  end

  defp input(options) do
    options
    |> Keyword.merge(owner: self(), tag: __MODULE__, vad: {Detector, []}, reorder_window: 4)
    |> RtpInput.new()
    |> RtpInput.restart(PCMUDecoder.new(), 8000)
  end

  defp packet(sequence, timestamp \\ nil),
    do: %{
      sequence_number: sequence,
      timestamp: timestamp || sequence * 160,
      payload: :binary.copy(<<255>>, 160)
    }

  defp push_all(input, packets) do
    Enum.reduce(packets, input, fn packet, input ->
      assert {:ok, input} = RtpInput.push(input, packet)
      input
    end)
  end

  test "a burst loss beyond the window is silence with loss: :silence and an error with :fail" do
    stream = Enum.map(0..2, &packet/1)
    jump = packet(100)

    assert {:ok, input} =
             stream |> then(&push_all(input(loss: :silence), &1)) |> RtpInput.push(jump)

    assert {:ok, _} = RtpInput.push(input, packet(101))

    assert {:error, :rtp_reorder_limit} =
             stream |> then(&push_all(input(loss: :fail), &1)) |> RtpInput.push(jump)
  end

  test "a timestamp jump is silence with loss: :silence and an error with :fail" do
    stream = Enum.map(0..2, &packet/1)
    dtx = packet(3, 20 * 160)

    assert {:ok, _} = stream |> then(&push_all(input(loss: :silence), &1)) |> RtpInput.push(dtx)

    assert {:error, :rtp_timestamp_gap} =
             stream |> then(&push_all(input(loss: :fail), &1)) |> RtpInput.push(dtx)
  end

  test "the gap timer gives up on a lost packet, or fails with loss: :fail" do
    stream = Enum.map([0, 1, 2, 4], &packet/1)

    silent = push_all(input(loss: :silence, gap_timeout_ms: 10), stream)
    {_, token} = silent.gap
    assert {:ok, %{gap: nil}} = RtpInput.gap(silent, token)

    strict = push_all(input(loss: :fail, gap_timeout_ms: 10), stream)
    {_, token} = strict.gap
    assert {:error, :rtp_gap_timeout} = RtpInput.gap(strict, token)
    assert {:ok, ^strict} = RtpInput.gap(strict, make_ref())
  end

  test "the held start of a stream is released by the gap timer without an error" do
    held = push_all(input(loss: :fail, gap_timeout_ms: 10), [packet(5)])
    {_, token} = held.gap
    assert {:ok, %{gap: nil, next_timestamp: 960}} = RtpInput.gap(held, token)
  end

  describe "semantic turn checks" do
    defp voice_input do
      [
        owner: self(),
        tag: __MODULE__,
        vad: {AudioFlow.Test.AmplitudeDetector, []},
        voice_input: [
          min_speech_ms: 20,
          min_silence_ms: 20,
          pre_roll_ms: 0,
          turn_timeout_ms: 5000,
          turn_detector: {AudioFlow.Test.GatedTurn, owner: self()}
        ]
      ]
    end

    test "a resolved check submits the utterance and tells the owner" do
      {:ok, session} = AudioFlow.start_session(Demo.options())
      on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)

      input =
        voice_input()
        |> RtpInput.new()
        |> RtpInput.restart(PCMUDecoder.new(), 8000)

      input = %{input | session: session}
      assert input.voice.semantic.async

      loud = %{sequence_number: 0, timestamp: 0, payload: :binary.copy(<<156>>, 160)}

      quiet = fn n ->
        %{sequence_number: n, timestamp: n * 160, payload: :binary.copy(<<255>>, 160)}
      end

      input = push_all(input, [loud | Enum.map(1..4, quiet)])

      assert_receive {:turn_gate, gate, _audio}
      assert input.voice.turn
      refute_received {AudioFlow.Transport.RtpInputTest, _, {:utterance, _}}

      # Packets keep arriving while the detector works.
      input = push_all(input, Enum.map(5..6, quiet))

      send(gate, :release)
      assert_receive {:audio_flow_turn, _, _} = message
      assert {:ok, input} = RtpInput.handle_info(input, message)
      assert input.voice.turn == nil
      assert_receive {AudioFlow.Transport.RtpInputTest, _, {:utterance, :semantic}}
      assert RtpInput.handle_info(input, :other) == :unknown
    end
  end
end
