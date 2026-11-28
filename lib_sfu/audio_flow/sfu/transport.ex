defmodule AudioFlow.SFU.Transport do
  @moduledoc """
  Bounded, paced Opus output to an AudioFlow SFU room. Implements
  `AudioFlow.Output`.

  Accepts mono PCM16LE at any rate, resamples it to 48 kHz, encodes 20 ms
  Opus frames and sends one RTP map every 20 ms to the native participant:
  `{:audio_flow_sfu, 1, {:rtp, track_sid, rtp}}`. Queue overflow fails the
  turn. `finish/2` drains (with a padded final frame); `flush/2` discards
  pending audio. Sent audio cannot be recalled and never implies playout.
  """
  use GenServer
  @behaviour AudioFlow.Output
  alias AudioFlow.Audio
  alias AudioFlow.Resampler
  alias Membrane.Opus.Encoder.Native, as: Encoder

  @rate 48_000
  @frame_bytes 1920
  # libopus OPUS_APPLICATION_VOIP, OPUS_AUTO bitrate, OPUS_SIGNAL_VOICE.
  @application 2048
  @bitrate -1000
  @signal 3001

  @vsn 1

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl AudioFlow.Output
  def start_turn(pid, key), do: GenServer.call(pid, {:start, key})
  @impl AudioFlow.Output
  def push(pid, key, audio), do: GenServer.call(pid, {:push, key, audio})
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
    do: {:reply, :ok, %{s | participant: participant, track: track}}

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

  def handle_call({:push, _, audio}, _, s) do
    cond do
      not Audio.valid?(audio) ->
        {:reply, {:error, :unsupported_pcm}, s}

      s.sealed or (s.rate != nil and s.rate != audio.sample_rate) ->
        {:reply, {:error, :output_format_changed}, s}

      true ->
        s = %{s | rate: audio.sample_rate, resampler: s.resampler || resampler(audio.sample_rate)}
        enqueue(s, resample(s.resampler, audio.data))
    end
  end

  def handle_call({:finish, _}, _, s) do
    tail = if s.resampler, do: Resampler.flush(s.resampler), else: <<>>
    data = s.pending <> tail
    padding = rem(@frame_bytes - rem(byte_size(data), @frame_bytes), @frame_bytes)

    case enqueue(%{s | pending: <<>>}, data <> <<0::size(padding * 8)>>) do
      # The session calls finish inside its server. Keep draining afterwards
      # so that it can still accept cancellation and deadline messages.
      {:reply, :ok, s} -> {:reply, :ok, schedule(%{s | sealed: true, resampler: nil})}
      error -> error
    end
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
        timestamp: rem(s.timestamp + 960, 4_294_967_296),
        next_at: System.monotonic_time(:millisecond) + 20
    }

    {:noreply, schedule(s)}
  end

  def handle_info(_, s), do: {:noreply, s}

  # 48 kHz audio needs no resampler.
  defp resampler(@rate), do: nil
  defp resampler(rate), do: Resampler.new(rate, @rate)

  defp resample(nil, data), do: data
  defp resample(resampler, data), do: Resampler.push(resampler, data)

  defp enqueue(s, data) do
    data = s.pending <> data
    count = div(byte_size(data), @frame_bytes)

    if :queue.len(s.queue) + count > s.limit do
      {:reply, {:error, :queue_limit}, s}
    else
      size = count * @frame_bytes
      <<frames::binary-size(^size), rest::binary>> = data

      queue =
        for <<frame::binary-size(@frame_bytes) <- frames>>, reduce: s.queue do
          queue ->
            {:ok, packet} = Encoder.encode_packet(s.encoder, frame, div(@frame_bytes, 2))
            :queue.in(packet, queue)
        end

      {:reply, :ok, schedule(%{s | queue: queue, pending: rest})}
    end
  end

  defp schedule(%{timer: nil} = s) do
    if :queue.is_empty(s.queue) do
      s
    else
      token = make_ref()
      delay = max(0, s.next_at - System.monotonic_time(:millisecond))
      %{s | timer: {Process.send_after(self(), {:tick, token}, delay), token}}
    end
  end

  defp schedule(s), do: s

  defp clear(s) do
    if s.timer, do: Process.cancel_timer(elem(s.timer, 0))

    %{
      s
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
