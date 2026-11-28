defmodule AudioFlow.WebRTC.Transport do
  @moduledoc """
  Bounded, paced PCMU output for a WebRTC peer. Implements `AudioFlow.Output`.
  Accepts mono PCM16LE at 8 or 16 kHz, preserving resampler state across chunks.
  Packets leave on absolute 20 ms deadlines. After silence the presentation
  time skips the idle time, which moves the RTP timestamp, and the peer marks
  the first packet of the new talkspurt.

  `push/3` applies back pressure: while `:max_queue_packets` (default 100, 2 s)
  are queued, a push waits until enough audio has left, and `flush/2`, a new
  turn or a stop release it with `{:error, :stale_turn}`. A push into an empty
  queue is always accepted. `finish/2` never waits: it drains, including a
  padded final packet. `flush/2` discards pending media. Sent RTP cannot be
  recalled and never implies remote playout.
  """
  use GenServer
  @behaviour AudioFlow.Output
  alias AudioFlow.Audio
  alias AudioFlow.Telephony.Packetizer
  alias AudioFlow.WebRTC

  @frame_ms 20
  # A stream that is later than this resyncs to the clock instead of bursting.
  @max_behind_ms 60

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl true
  def start_turn(pid, key), do: GenServer.call(pid, {:start, key})
  @impl true
  def push(pid, key, audio), do: GenServer.call(pid, {:push, key, audio}, :infinity)
  @impl true
  def finish(pid, key), do: GenServer.call(pid, {:finish, key}, :infinity)
  @impl true
  def flush(pid, key), do: GenServer.call(pid, {:flush, key})

  # State version for hot code upgrades. Bump it when the state shape changes,
  # and migrate the old state in code_change/3 (see the hot-upgrades guide).
  @vsn 1

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  @impl true
  def init(opts) do
    peer = Keyword.fetch!(opts, :peer)
    Process.monitor(peer)
    limit = Keyword.get(opts, :max_queue_packets, 100)
    unless is_integer(limit) and limit in 1..1500, do: raise(ArgumentError, "invalid queue limit")

    {:ok,
     %{
       peer: peer,
       owner: Keyword.get(opts, :owner),
       limit: limit,
       key: nil,
       queue: :queue.new(),
       packetizer: %Packetizer{},
       timer: nil,
       held: nil,
       spurt: true,
       sealed: false,
       pts: 0,
       next_at: nil,
       error: nil
     }}
  end

  @impl true
  def handle_call({:start, key}, _, s) when not is_nil(key) do
    s = clear(s)
    result = WebRTC.start_turn(s.peer, key)
    {:reply, result, %{s | key: key}}
  end

  def handle_call({:flush, key}, _, %{key: key} = s) do
    WebRTC.flush(s.peer, key)
    {:reply, :ok, %{clear(s) | key: nil}}
  end

  def handle_call({:flush, _}, _, s), do: {:reply, :ok, s}

  def handle_call({action, key, _}, _, s) when action == :push and (key == nil or key != s.key),
    do: {:reply, {:error, :stale_turn}, s}

  def handle_call({:finish, key}, _, s) when key == nil or key != s.key,
    do: {:reply, {:error, :stale_turn}, s}

  def handle_call({:push, _, _}, _, %{error: error} = s) when error != nil,
    do: {:reply, {:error, error}, s}

  def handle_call({:finish, _}, _, %{error: error} = s) when error != nil,
    do: {:reply, {:error, error}, s}

  def handle_call({:finish, _}, _, %{sealed: true} = s), do: {:reply, :ok, s}

  def handle_call({:push, _, _}, _, %{held: held} = s) when held != nil,
    do: {:reply, {:error, :push_pending}, s}

  def handle_call({:push, _, audio}, from, s) do
    case push_error(audio, s) do
      nil -> push_audio(audio, from, s)
      reason -> {:reply, {:error, reason}, s}
    end
  end

  # The session calls finish inside its server, so it never waits for room.
  # Keep draining afterwards so that it can still accept cancellation and
  # deadline messages.
  def handle_call({:finish, _}, _from, s) do
    {packets, packetizer} = Packetizer.finish(s.packetizer)
    s = enqueue(%{s | packetizer: packetizer}, packets)
    {:reply, :ok, schedule(%{s | sealed: true})}
  end

  @impl true
  def handle_info({:tick, token}, %{timer: {_, token}} = s) do
    {{:value, packet}, queue} = :queue.out(s.queue)

    case WebRTC.publish(s.peer, s.key, :audio, packet, s.pts) do
      :ok ->
        s = %{
          s
          | queue: queue,
            timer: nil,
            spurt: false,
            pts: s.pts + @frame_ms * 1000,
            # The next deadline follows the previous one, not the time of this tick.
            next_at: s.next_at + @frame_ms
        }

        {:noreply, s |> admit_held() |> schedule()}

      {:error, reason} ->
        WebRTC.flush(s.peer, s.key)
        if s.owner, do: send(s.owner, {__MODULE__, self(), {:error, reason}})
        {:noreply, %{clear(s) | error: reason}}
    end
  end

  def handle_info({:DOWN, _, :process, _, _}, s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s), do: clear(s)

  defp push_error(audio, s) do
    cond do
      not Audio.valid?(audio) or audio.sample_rate not in [8000, 16_000] ->
        :unsupported_pcm

      s.sealed or (s.packetizer.rate != nil and s.packetizer.rate != audio.sample_rate) ->
        :output_format_changed

      true ->
        nil
    end
  end

  defp push_audio(audio, from, s) do
    {packets, packetizer} = Packetizer.push(audio, s.packetizer)
    admit(%{s | packetizer: packetizer}, from, packets)
  end

  # Accepts packets that fit in the queue, or any packets when the queue is
  # empty. Otherwise the push waits in `held` and its reply waits with it.
  defp admit(s, from, packets) do
    if fits?(s, packets) do
      {:reply, :ok, schedule(enqueue(s, packets))}
    else
      {:noreply, %{s | held: {from, packets}}}
    end
  end

  defp admit_held(%{held: {from, packets}} = s) do
    if fits?(s, packets) do
      GenServer.reply(from, :ok)
      enqueue(%{s | held: nil}, packets)
    else
      s
    end
  end

  defp admit_held(s), do: s

  defp fits?(s, packets) do
    count = length(packets)
    count == 0 or :queue.is_empty(s.queue) or :queue.len(s.queue) + count <= s.limit
  end

  defp enqueue(s, packets), do: %{s | queue: Enum.reduce(packets, s.queue, &:queue.in/2)}

  defp schedule(%{timer: nil} = s) do
    if :queue.is_empty(s.queue) do
      s
    else
      s = resync(s, System.monotonic_time(:millisecond))
      token = make_ref()
      timer = Process.send_after(self(), {:tick, token}, s.next_at, abs: true)
      %{s | timer: {timer, token}}
    end
  end

  defp schedule(s), do: s

  # The start of a talkspurt, or a stream that fell far behind, begins at the
  # clock. The presentation time skips the idle time, so the peer sees a gap in
  # the RTP timestamps and marks the first packet of the new talkspurt.
  defp resync(%{next_at: nil} = s, now), do: %{s | next_at: now}

  defp resync(s, now) do
    behind = now - s.next_at

    if behind > @max_behind_ms or (s.spurt and behind > 0),
      do: %{s | next_at: now, pts: s.pts + behind * 1000},
      else: s
  end

  # Answers a waiting push, because its turn has ended.
  defp release(%{held: {from, _}} = s) do
    GenServer.reply(from, {:error, :stale_turn})
    %{s | held: nil}
  end

  defp release(s), do: s

  defp clear(s) do
    if s.timer, do: Process.cancel_timer(elem(s.timer, 0))

    %{
      release(s)
      | queue: :queue.new(),
        packetizer: %Packetizer{},
        timer: nil,
        sealed: false,
        spurt: true,
        error: nil
    }
  end
end
