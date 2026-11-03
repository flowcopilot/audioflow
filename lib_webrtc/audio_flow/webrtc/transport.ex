defmodule AudioFlow.WebRTC.Transport do
  @moduledoc """
  Bounded, paced PCMU output for a WebRTC peer. Implements `AudioFlow.Output`.
  Accepts mono PCM16LE at 8 or 16 kHz, preserving resampler state across chunks.
  Queue overflow fails the turn rather than growing latency without bound.
  `finish/2` drains (including a padded final packet); `flush/2` discards pending
  media. Sent RTP cannot be recalled and never implies remote playout.
  """
  use GenServer
  @behaviour AudioFlow.Output
  alias AudioFlow.Audio
  alias AudioFlow.Telephony.MuLaw
  alias AudioFlow.Telephony.RateConverter
  alias AudioFlow.WebRTC

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl true
  def start_turn(pid, key), do: GenServer.call(pid, {:start, key})
  @impl true
  def push(pid, key, audio), do: GenServer.call(pid, {:push, key, audio})
  @impl true
  def finish(pid, key), do: GenServer.call(pid, {:finish, key}, :infinity)
  @impl true
  def flush(pid, key), do: GenServer.call(pid, {:flush, key})

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
       pending: <<>>,
       rate: nil,
       converter: %RateConverter{},
       timer: nil,
       sealed: false,
       pts: 0,
       next_at: System.monotonic_time(:millisecond),
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

  def handle_call({:push, _, audio}, _, s) do
    case push_error(audio, s) do
      nil -> push_audio(audio, s)
      reason -> {:reply, {:error, reason}, s}
    end
  end

  def handle_call({:finish, _}, _from, s) do
    {tail, _} =
      if s.rate == 16_000,
        do: RateConverter.down(:binary.copy(<<0>>, 60), s.converter),
        else: {<<>>, s.converter}

    data = s.pending <> MuLaw.encode(tail)
    padding = rem(160 - rem(byte_size(data), 160), 160)

    case enqueue(data <> :binary.copy(<<255>>, padding), s) do
      {:ok, s} ->
        # Session invokes finish inside its server. Keep draining asynchronously
        # so that server can still accept cancellation and deadline messages.
        {:reply, :ok, schedule(%{s | sealed: true})}

      {:error, reason} ->
        {:reply, {:error, reason}, s}
    end
  end

  @impl true
  def handle_info({:tick, token}, %{timer: {_, token}} = s) do
    {{:value, packet}, queue} = :queue.out(s.queue)

    case WebRTC.publish(s.peer, s.key, :audio, packet, s.pts) do
      :ok ->
        # Relative scheduling prevents a delayed scheduler from bursting to catch up.
        s = %{
          s
          | queue: queue,
            timer: nil,
            pts: s.pts + 20_000,
            next_at: System.monotonic_time(:millisecond) + 20
        }

        {:noreply, schedule(s)}

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

      s.sealed or (s.rate != nil and s.rate != audio.sample_rate) ->
        :output_format_changed

      byte_size(audio.data) > s.limit * if(audio.sample_rate == 8000, do: 320, else: 640) ->
        :queue_limit

      true ->
        nil
    end
  end

  defp push_audio(audio, s) do
    {data, converter} =
      if audio.sample_rate == 16_000,
        do: RateConverter.down(audio.data, s.converter),
        else: {audio.data, s.converter}

    case enqueue(s.pending <> MuLaw.encode(data), %{
           s
           | converter: converter,
             rate: audio.sample_rate
         }) do
      {:ok, s} -> {:reply, :ok, schedule(s)}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  defp enqueue(data, s) do
    count = div(byte_size(data) + 159, 160)

    if :queue.len(s.queue) + count > s.limit do
      {:error, :queue_limit}
    else
      packets = for <<packet::binary-size(160) <- data>>, do: packet
      rest = rem(byte_size(data), 160)

      {:ok,
       %{
         s
         | queue: Enum.reduce(packets, s.queue, &:queue.in/2),
           pending: binary_part(data, byte_size(data) - rest, rest)
       }}
    end
  end

  defp schedule(%{timer: nil} = s) do
    if :queue.is_empty(s.queue) do
      s
    else
      token = make_ref()
      delay = max(0, s.next_at - System.monotonic_time(:millisecond))
      timer = Process.send_after(self(), {:tick, token}, delay)
      %{s | timer: {timer, token}}
    end
  end

  defp schedule(s), do: s

  defp clear(s) do
    if s.timer, do: Process.cancel_timer(elem(s.timer, 0))

    %{
      s
      | queue: :queue.new(),
        pending: <<>>,
        converter: %RateConverter{},
        timer: nil,
        sealed: false,
        rate: nil,
        error: nil
    }
  end
end
