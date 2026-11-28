# Telephony codec contention benchmark. No models, no network.
#
#     mix run bench/concurrency.exs [seconds_per_level]
#
# N processes each handle one call at 50 packets/s (20 ms of 8 kHz audio). One
# packet is the inbound path (MuLaw.decode, RateConverter.up) followed by the
# outbound path (Packetizer.push: RateConverter.down, MuLaw.encode). These are
# the NIFs behind web_socket.ex and packetizer.ex, so the table shows dirty
# scheduler contention that bench/hot_paths.exs, with one process, cannot.
#
# Latency is the time one process spends on one packet, queueing for a dirty
# scheduler included. Late packets took longer than the 20 ms packet interval.
alias AudioFlow.Audio
alias AudioFlow.Telephony.MuLaw
alias AudioFlow.Telephony.Packetizer
alias AudioFlow.Telephony.RateConverter

defmodule Bench.Concurrency do
  @interval_ms 20

  def level(count, seconds, ulaw) do
    parent = self()
    packets = div(seconds * 1000, @interval_ms)
    start = System.monotonic_time(:millisecond) + 200

    for index <- 1..count do
      spawn_link(fn ->
        # Spread the calls over one interval, as real calls are not in phase.
        offset = rem(index * 7, @interval_ms)
        send(parent, {:done, call(packets, start + offset, ulaw)})
      end)
    end

    latencies = for _ <- 1..count, reduce: [], do: (acc -> receive(do: ({:done, l} -> l ++ acc)))
    Enum.sort(latencies)
  end

  defp call(packets, start, ulaw) do
    state = {%RateConverter{}, %Packetizer{}}

    {latencies, _} =
      Enum.reduce(0..(packets - 1), {[], state}, fn index, {latencies, state} ->
        wait = start + index * @interval_ms - System.monotonic_time(:millisecond)
        if wait > 0, do: Process.sleep(wait)
        {us, state} = :timer.tc(fn -> packet(ulaw, state) end)
        {[us | latencies], state}
      end)

    latencies
  end

  defp packet(ulaw, {up, packetizer}) do
    {pcm16, up} = RateConverter.up(MuLaw.decode(ulaw), up)
    {_packets, packetizer} = Packetizer.push(%Audio{data: pcm16, sample_rate: 16_000}, packetizer)
    {up, packetizer}
  end
end

seconds =
  case System.argv() do
    [value | _] -> String.to_integer(value)
    [] -> 5
  end

ulaw = :crypto.strong_rand_bytes(160)

IO.puts(
  "schedulers #{System.schedulers_online()}, dirty cpu #{:erlang.system_info(:dirty_cpu_schedulers_online)}, " <>
    "#{seconds} s per level, 50 packets/s per call"
)

IO.puts("calls   packets   p50 us   p99 us   max us   late (>20 ms)")

# Warm the NIFs and the allocators before the first measured level.
Bench.Concurrency.level(10, 1, ulaw)

for count <- [1, 50, 200, 500] do
  latencies = Bench.Concurrency.level(count, seconds, ulaw)
  n = length(latencies)
  at = fn q -> Enum.at(latencies, min(n - 1, trunc(n * q))) end

  IO.puts(
    String.pad_leading("#{count}", 5) <>
      String.pad_leading("#{n}", 10) <>
      String.pad_leading("#{at.(0.5)}", 9) <>
      String.pad_leading("#{at.(0.99)}", 9) <>
      String.pad_leading("#{List.last(latencies)}", 9) <>
      String.pad_leading("#{Enum.count(latencies, &(&1 > 20_000))}", 15)
  )
end
