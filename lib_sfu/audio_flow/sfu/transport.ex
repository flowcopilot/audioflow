defmodule AudioFlow.SFU.Transport do
  @moduledoc """
  Bounded, paced Opus output to an AudioFlow SFU room. Implements
  `AudioFlow.Output`.

  Accepts mono PCM16LE at any rate, resamples it to 48 kHz, encodes 20 ms
  Opus frames and sends one RTP map every 20 ms to the native participant:
  `{:audio_flow_sfu, 1, {:rtp, track_sid, rtp}}`. Packets leave on absolute
  20 ms deadlines, so a late tick does not slow the stream. After silence the
  RTP timestamp skips the idle time and the first packet of the new talkspurt
  has the marker bit.

  `push/3` applies back pressure: while `:max_queue_packets` (default 100,
  2 s) are queued, a push waits until enough audio has left, and `flush/2`,
  a new turn, `retarget/3` or a stop release it with `{:error, :stale_turn}`.
  A push into an empty queue is always accepted. `finish/2` never waits: it
  drains with a padded final frame. `flush/2` discards pending audio. Sent
  audio cannot be recalled and never implies playout.
  """
  use GenServer
  @behaviour AudioFlow.Output
  alias AudioFlow.Audio
  alias AudioFlow.Resampler
  alias Membrane.Opus.Encoder.Native, as: Encoder

  @rate 48_000
  @frame_bytes 1920
  @frame_ms 20
  @samples_per_ms 48
  # A stream that is later than this resyncs to the clock instead of bursting.
  @max_behind_ms 60
  @timestamp_modulus 4_294_967_296
  # libopus OPUS_APPLICATION_VOIP, OPUS_AUTO bitrate, OPUS_SIGNAL_VOICE.
  @application 2048
  @bitrate -1000
  @signal 3001

  @vsn 1

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl AudioFlow.Output
  def start_turn(pid, key), do: GenServer.call(pid, {:start, key})
  @impl AudioFlow.Output
  def push(pid, key, audio), do: GenServer.call(pid, {:push, key, audio}, :infinity)
  @impl AudioFlow.Output
  def finish(pid, key), do: GenServer.call(pid, {:finish, key}, :infinity)
  @impl AudioFlow.Output
  def flush(pid, key), do: GenServer.call(pid, {:flush, key})

  @impl GenServer
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  @impl GenServer
  def init(options) do
    limit = Keyword.get(options, :max_queue_packets, 100)
    unless is_integer(limit) and limit in 1..1500, do: raise(ArgumentError, "invalid queue limit")

    {:ok,
     %{
       participant: Keyword.fetch!(options, :participant),
       track: Keyword.fetch!(options, :track),
       owner: Keyword.get(options, :owner),
       limit: limit,
       encoder: Encoder.create(@rate, 1, @application, @bitrate, @signal),
       key: nil,
       resampler: nil,
       rate: nil,
       pending: <<>>,
       queue: :queue.new(),
       timer: nil,
       held: nil,
       sealed: false,
       sequence: :rand.uniform(65_536) - 1,
       timestamp: :rand.uniform(4_294_967_296) - 1,
       marker: true,
       next_at: System.monotonic_time(:millisecond),
       error: nil
     }}
  end

  @doc "Moves the output to a new participant, after an agent rejoins a room."
  def retarget(pid, participant, track), do: GenServer.call(pid, {:retarget, participant, track})

  @impl GenServer
  def handle_call({:retarget, participant, track}, _, s),
    do: {:reply, :ok, %{release(s) | participant: participant, track: track}}

  def handle_call({:start, key}, _, s) when not is_nil(key),
    do: {:reply, :ok, %{clear(s) | key: key}}

  def handle_call({:flush, key}, _, %{key: key} = s), do: {:reply, :ok, %{clear(s) | key: nil}}
  def handle_call({:flush, _}, _, s), do: {:reply, :ok, s}

  def handle_call({action, key, _}, _, s) when action == :push and (key == nil or key != s.key),
    do: {:reply, {:error, :stale_turn}, s}

  def handle_call({:finish, key}, _, s) when key == nil or key != s.key,
    do: {:reply, {:error, :stale_turn}, s}

  def handle_call({_, _, _}, _, %{error: error} = s) when error != nil,
    do: {:reply, {:error, error}, s}

  def handle_call({:finish, _}, _, %{error: error} = s) when error != nil,
    do: {:reply, {:error, error}, s}

  def handle_call({:finish, _}, _, %{sealed: true} = s), do: {:reply, :ok, s}

  def handle_call({:push, _, _}, _, %{held: held} = s) when held != nil,
    do: {:reply, {:error, :push_pending}, s}

  def handle_call({:push, _, audio}, from, s) do
    cond do
      not Audio.valid?(audio) ->
        {:reply, {:error, :unsupported_pcm}, s}

      s.sealed or (s.rate != nil and s.rate != audio.sample_rate) ->
        {:reply, {:error, :output_format_changed}, s}

      true ->
        s = %{s | rate: audio.sample_rate, resampler: s.resampler || resampler(audio.sample_rate)}
        data = s.pending <> resample(s.resampler, audio.data)
        admit(%{s | pending: <<>>}, from, data)
    end
  end

  # The session calls finish inside its server, so it never waits for room.
  def handle_call({:finish, _}, _, s) do
    tail = if s.resampler, do: Resampler.flush(s.resampler), else: <<>>
    data = s.pending <> tail
    padding = rem(@frame_bytes - rem(byte_size(data), @frame_bytes), @frame_bytes)

    # Keep draining afterwards so that the session can still accept
    # cancellation and deadline messages.
    s = enqueue(%{s | pending: <<>>}, data <> <<0::size(padding * 8)>>)
    {:reply, :ok, schedule(%{s | sealed: true, resampler: nil})}
  end

  @impl GenServer
  def handle_info({:tick, token}, %{timer: {_, token}} = s) do
    {{:value, payload}, queue} = :queue.out(s.queue)

    rtp = %{
      sequence_number: s.sequence,
      timestamp: s.timestamp,
      marker: s.marker,
      payload: payload
    }

    # A busy distribution connection drops the packet: late audio has no value.
    :erlang.send(s.participant, {:audio_flow_sfu, 1, {:rtp, s.track, rtp}}, [:nosuspend])

    s = %{
      s
      | queue: queue,
        timer: nil,
        marker: false,
        sequence: rem(s.sequence + 1, 65_536),
        timestamp: rem(s.timestamp + @frame_ms * @samples_per_ms, @timestamp_modulus),
        # The next deadline follows the previous one, not the time of this tick.
        next_at: s.next_at + @frame_ms
    }

    {:noreply, s |> admit_held() |> schedule()}
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl GenServer
  def terminate(_, s) do
    release(s)
    :ok
  end

  # 48 kHz audio needs no resampler.
  defp resampler(@rate), do: nil
  defp resampler(rate), do: Resampler.new(rate, @rate)

  defp resample(nil, data), do: data
  defp resample(resampler, data), do: Resampler.push(resampler, data)

  # Accepts audio that fits in the queue, or any audio when the queue is empty.
  # Otherwise the push waits in `held` and its reply waits with it.
  defp admit(s, from, data) do
    if fits?(s, data) do
      {:reply, :ok, enqueue(s, data)}
    else
      {:noreply, %{s | held: {from, data}}}
    end
  end

  defp admit_held(%{held: {from, data}} = s) do
    if fits?(s, data) do
      GenServer.reply(from, :ok)
      enqueue(%{s | held: nil}, data)
    else
      s
    end
  end

  defp admit_held(s), do: s

  defp fits?(s, data) do
    count = div(byte_size(data), @frame_bytes)
    count == 0 or :queue.is_empty(s.queue) or :queue.len(s.queue) + count <= s.limit
  end

  defp enqueue(s, data) do
    size = div(byte_size(data), @frame_bytes) * @frame_bytes
    <<frames::binary-size(^size), rest::binary>> = data

    queue =
      for <<frame::binary-size(@frame_bytes) <- frames>>, reduce: s.queue do
        queue ->
          {:ok, packet} = Encoder.encode_packet(s.encoder, frame, div(@frame_bytes, 2))
          :queue.in(packet, queue)
      end

    schedule(%{s | queue: queue, pending: rest})
  end

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
  # clock. The RTP timestamp skips the idle time, and the marker bit tells the
  # receiver that a new talkspurt starts.
  defp resync(s, now) do
    behind = now - s.next_at

    if behind > @max_behind_ms or (s.marker and behind > 0) do
      %{
        s
        | next_at: now,
          marker: true,
          timestamp: rem(s.timestamp + behind * @samples_per_ms, @timestamp_modulus)
      }
    else
      s
    end
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
        pending: <<>>,
        resampler: nil,
        rate: nil,
        timer: nil,
        sealed: false,
        marker: true,
        error: nil
    }
  end
end
