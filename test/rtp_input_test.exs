defmodule AudioFlow.Transport.RtpInputTest do
  use ExUnit.Case, async: true
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
end
