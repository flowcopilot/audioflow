# Playback demand benchmark: does small-chunk TTS output starve a real-time sink?
#
#     AUDIOFLOW_MEDIA=1 mix run bench/playback.exs
#
# A sink asks for one buffer per chunk period, like a device callback. TTS
# delivers each chunk as fast as Playback accepts it. For every chunk size the
# table reports the wait from a sink request to its buffer (p50, p99, max) and
# the underruns: requests that waited longer than one chunk period.
unless System.get_env("AUDIOFLOW_MEDIA") == "1" do
  IO.puts("Set AUDIOFLOW_MEDIA=1 to run this benchmark.")
  System.halt(0)
end

Logger.configure(level: :warning)

defmodule Bench.ClockSink do
  @moduledoc false
  use Membrane.Sink

  def_options(
    owner: [spec: pid()],
    period_ms: [spec: pos_integer()],
    expected: [spec: pos_integer()]
  )

  def_input_pad(:input,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: %Membrane.RawAudio{channels: 1, sample_format: :s16le}
  )

  def handle_init(_ctx, options),
    do:
      {[],
       %{
         owner: options.owner,
         period_ms: options.period_ms,
         expected: options.expected,
         timer: nil,
         pending: nil,
         waits: []
       }}

  def handle_playing(_ctx, state) do
    send(state.owner, {:sink_ready, self()})
    {[], state}
  end

  def handle_info(:start, _ctx, state) do
    {:ok, timer} = :timer.send_interval(state.period_ms, :tick)
    {[], %{state | timer: timer}}
  end

  def handle_info(:tick, _ctx, %{pending: nil} = state),
    do: {[demand: {:input, 1}], %{state | pending: System.monotonic_time(:microsecond)}}

  # A tick queued behind a slow scheduler turn is not a starved request.
  def handle_info(:tick, _ctx, state), do: {[], state}

  def handle_buffer(:input, _buffer, _ctx, state) do
    wait = System.monotonic_time(:microsecond) - state.pending
    waits = [wait | state.waits]

    if length(waits) == state.expected do
      :timer.cancel(state.timer)
      send(state.owner, {:report, waits})
    end

    {[], %{state | pending: nil, waits: waits}}
  end
end

defmodule Bench.Playback do
  alias AudioFlow.Audio
  alias AudioFlow.Playback

  @rate 16_000

  def run(chunk_ms, seconds) do
    count = div(seconds * 1000, chunk_ms)
    bytes = div(chunk_ms * @rate, 1000) * 2
    chunk = %Audio{data: :binary.copy(<<1, 0>>, div(bytes, 2)), sample_rate: @rate}
    sink = %Bench.ClockSink{owner: self(), period_ms: chunk_ms, expected: count}
    {:ok, player} = Playback.start_link(sink: sink, max_bytes: max(bytes * 8, 4096))
    key = {self(), make_ref()}
    :ok = Playback.start_turn(player, key)
    :ok = Playback.push(player, key, chunk)

    sink_pid =
      receive do
        {:sink_ready, pid} -> pid
      after
        10_000 -> raise "sink did not start"
      end

    send(sink_pid, :start)
    for _ <- 2..count, do: :ok = Playback.push(player, key, chunk)
    :ok = Playback.finish(player, key)

    receive do
      {:report, waits} ->
        GenServer.stop(player)
        {Enum.sort(waits), Enum.count(waits, &(&1 > chunk_ms * 1000))}
    after
      seconds * 1000 + 5000 -> raise "sink did not finish"
    end
  end

  def row(chunk_ms, seconds) do
    {waits, underruns} = run(chunk_ms, seconds)
    n = length(waits)
    at = fn q -> Enum.at(waits, min(n - 1, trunc(n * q))) end

    IO.puts(
      String.pad_leading("#{chunk_ms}", 8) <>
        String.pad_leading("#{n}", 9) <>
        String.pad_leading("#{at.(0.5)}", 9) <>
        String.pad_leading("#{at.(0.99)}", 9) <>
        String.pad_leading("#{List.last(waits)}", 9) <>
        String.pad_leading("#{underruns}", 12)
    )
  end
end

IO.puts("chunk ms   served   p50 us   p99 us   max us   underruns")
for chunk_ms <- [5, 10, 20, 40, 100], do: Bench.Playback.row(chunk_ms, 5)
