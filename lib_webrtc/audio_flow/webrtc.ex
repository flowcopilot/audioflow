defmodule AudioFlow.WebRTC do
  @moduledoc """
  Optional encoded-media peer. Enable AUDIOFLOW_WEBRTC=1.

  The owner exchanges `{:signal, map}` events through its authenticated signaling
  channel and calls `signal/2` for remote SDP/ICE. Incoming tracks, RTP and RTCP
  are forwarded as `{:media, event}`. This is not a PCM Session transport.

  `publish/5` sends one encoded VP8 frame or 20 ms PCMU packet. `pts_us` is
  relative to a shared audio/video epoch; the producer must pace calls in real
  time. No encoder, decoder, jitter buffer or playout acknowledgement is implied.
  Flush invalidates the generation key, preventing stale producers from sending.
  """
  use GenServer

  alias ExWebRTC.{
    PeerConnection,
    MediaStreamTrack,
    SessionDescription,
    ICECandidate,
    RTPCodecParameters
  }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def offer(pid), do: GenServer.call(pid, :offer)
  def signal(pid, message), do: GenServer.call(pid, {:signal, message})
  def start_turn(pid, key), do: GenServer.call(pid, {:turn, key})
  def flush(pid, key), do: GenServer.call(pid, {:flush, key})

  def publish(pid, key, kind, data, pts_us),
    do: GenServer.call(pid, {:publish, key, kind, data, pts_us})

  def stop(pid), do: GenServer.stop(pid)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)

    audio = %RTPCodecParameters{
      payload_type: 0,
      mime_type: "audio/PCMU",
      clock_rate: 8000,
      channels: 1
    }

    {:ok, pc} =
      PeerConnection.start_link(
        ice_servers: Keyword.get(opts, :ice_servers, []),
        audio_codecs: [audio],
        video_codecs: [:vp8]
      )

    tracks =
      Map.new([:audio, :video], fn kind ->
        track = MediaStreamTrack.new(kind)
        {:ok, _} = PeerConnection.add_track(pc, track)
        {kind, track.id}
      end)

    timer =
      Process.send_after(
        self(),
        :negotiation_timeout,
        Keyword.get(opts, :negotiation_timeout_ms, 15_000)
      )

    {:ok,
     %{
       owner: owner,
       pc: pc,
       tracks: tracks,
       connected: false,
       timer: timer,
       key: nil,
       seq: %{audio: 0, video: 0},
       pts: %{}
     }}
  end

  @impl true
  def handle_call(:offer, _, s) do
    with {:ok, offer} <- PeerConnection.create_offer(s.pc),
         :ok <- PeerConnection.set_local_description(s.pc, offer) do
      {:reply, {:ok, SessionDescription.to_json(offer)}, s}
    else
      error -> {:reply, error, s}
    end
  end

  def handle_call({:signal, %{"type" => type, "sdp" => sdp} = json}, _, s)
      when type in ["offer", "answer"] and is_binary(sdp) and byte_size(sdp) <= 65_536 do
    result =
      with :ok <- PeerConnection.set_remote_description(s.pc, SessionDescription.from_json(json)) do
        if type == "offer" do
          with {:ok, answer} <- PeerConnection.create_answer(s.pc),
               :ok <- PeerConnection.set_local_description(s.pc, answer) do
            send(s.owner, {__MODULE__, self(), {:signal, SessionDescription.to_json(answer)}})
            :ok
          end
        else
          :ok
        end
      end

    {:reply, result, s}
  rescue
    _ -> {:reply, {:error, :invalid_signal}, s}
  end

  def handle_call({:signal, %{"type" => "candidate", "candidate" => nil}}, _, s),
    do: {:reply, :ok, s}

  def handle_call(
        {:signal, %{"type" => "candidate", "candidate" => %{"candidate" => line} = json}},
        _,
        s
      )
      when is_binary(line) and byte_size(line) <= 4096 do
    result =
      PeerConnection.add_ice_candidate(s.pc, ICECandidate.from_json(json))

    {:reply, result, s}
  rescue
    _ -> {:reply, {:error, :invalid_signal}, s}
  end

  def handle_call({:signal, _}, _, s), do: {:reply, {:error, :invalid_signal}, s}
  def handle_call({:turn, key}, _, s) when not is_nil(key), do: {:reply, :ok, %{s | key: key}}

  def handle_call({:flush, key}, _, s),
    do: {:reply, :ok, if(s.key == key, do: %{s | key: nil}, else: s)}

  def handle_call({:publish, key, kind, data, pts}, _, s) do
    cond do
      key == nil or key != s.key ->
        {:reply, {:error, :stale_turn}, s}

      not s.connected ->
        {:reply, {:error, :not_connected}, s}

      not valid?(kind, data, pts) ->
        {:reply, {:error, :invalid_media}, s}

      pts < Map.get(s.pts, kind, 0) ->
        {:reply, {:error, :regressing_timestamp}, s}

      true ->
        chunks = if kind == :video, do: vp8(data), else: [data]

        timestamp =
          rem(div(pts * if(kind == :video, do: 90_000, else: 8000), 1_000_000), 4_294_967_296)

        seq =
          Enum.reduce(Enum.with_index(chunks), s.seq[kind], fn {payload, i}, seq ->
            packet =
              ExRTP.Packet.new(payload,
                timestamp: timestamp,
                sequence_number: seq,
                marker: kind == :video and i == length(chunks) - 1
              )

            PeerConnection.send_rtp(s.pc, s.tracks[kind], packet)
            rem(seq + 1, 65_536)
          end)

        {:reply, :ok, %{s | seq: Map.put(s.seq, kind, seq), pts: Map.put(s.pts, kind, pts)}}
    end
  end

  @impl true
  def handle_info({:ex_webrtc, pc, {:ice_candidate, candidate}}, %{pc: pc} = s) do
    send(
      s.owner,
      {__MODULE__, self(),
       {:signal, %{"type" => "candidate", "candidate" => ICECandidate.to_json(candidate)}}}
    )

    {:noreply, s}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, %{pc: pc} = s) do
    Process.cancel_timer(s.timer)
    send(s.owner, {__MODULE__, self(), :connected})
    {:noreply, %{s | connected: true}}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, state}}, %{pc: pc} = s)
      when state in [:failed, :closed], do: {:stop, :normal, s}

  def handle_info({:ex_webrtc, pc, event}, %{pc: pc} = s) do
    send(s.owner, {__MODULE__, self(), {:media, event}})
    {:noreply, s}
  end

  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = s), do: {:stop, :normal, s}
  def handle_info(:negotiation_timeout, %{connected: false} = s), do: {:stop, :normal, s}
  def handle_info({:EXIT, _, _}, s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}
  @impl true
  def terminate(_, s) do
    if Process.alive?(s.pc), do: PeerConnection.stop(s.pc)
    :ok
  end

  defp valid?(:audio, data, pts),
    do: is_binary(data) and byte_size(data) == 160 and is_integer(pts) and pts >= 0

  defp valid?(:video, data, pts),
    do: is_binary(data) and byte_size(data) in 1..262_144 and is_integer(pts) and pts >= 0

  defp valid?(_, _, _), do: false
  defp vp8(data), do: vp8(data, 0x10, [])
  defp vp8(<<>>, _, acc), do: Enum.reverse(acc)

  defp vp8(data, header, acc) do
    size = min(byte_size(data), 1199)
    <<chunk::binary-size(^size), rest::binary>> = data
    vp8(rest, 0, [<<header, chunk::binary>> | acc])
  end
end
