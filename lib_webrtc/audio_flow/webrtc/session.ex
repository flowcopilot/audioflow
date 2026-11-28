defmodule AudioFlow.WebRTC.Session do
  @moduledoc """
  Optional PCM Session owner over PCMU WebRTC. Requires `:owner`, `:session`
  (AudioFlow Session options) and `:vad` (VoiceInput detector tuple at 16 kHz).

  Explicitly route `{AudioFlow.WebRTC.Session, bridge, {:signal, map}}` through
  your signaling channel to the remote peer, and call `signal/2` for its maps.
  `offer/1` returns the initial SDP; it is not also emitted as an event.
  Other events are `:connected`, `{:session, turn, event}`, `{:utterance, reason}`
  and `{:error, reason}`. Session audio events describe generated PCM; only RTP
  carries playback audio. No remote playout acknowledgement is fabricated.

  One negotiated mono PCMU audio track is accepted. RTP must contain 20 ms
  packets, payload type 0, no simulcast RID. Sequence wrap and bounded reordering
  are supported; duplicates are dropped, gaps close after `:gap_timeout_ms`
  (200 ms). This deliberately fails on loss rather than inventing speech.
  `:reorder_window` defaults to 32 (max 256). VoiceInput handles silence/length
  endpoints; speech start cancels output. Owner/peer/session exit closes all work.
  """
  use GenServer
  alias AudioFlow.Transport.PCMUDecoder
  alias AudioFlow.Transport.RtpInput
  alias AudioFlow.WebRTC
  alias AudioFlow.WebRTC.Transport

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def offer(pid), do: GenServer.call(pid, :offer)
  def signal(pid, message), do: GenServer.call(pid, {:signal, message})
  def cancel(pid), do: GenServer.call(pid, :cancel)
  def submit(pid, input), do: GenServer.call(pid, {:submit, input})
  def stop(pid), do: GenServer.stop(pid)

  # State version for hot code upgrades. Bump it when the state shape changes,
  # and migrate the old state in code_change/3 (see the hot-upgrades guide).
  @vsn 1

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)

    input =
      RtpInput.new(
        owner: owner,
        tag: __MODULE__,
        vad: Keyword.fetch!(opts, :vad),
        voice_input: Keyword.get(opts, :voice_input, []),
        reorder_window: Keyword.get(opts, :reorder_window, 32),
        gap_timeout_ms: Keyword.get(opts, :gap_timeout_ms, 200),
        loss: :fail
      )

    {:ok, peer} =
      WebRTC.start_link(
        Keyword.put(
          Keyword.take(
            opts,
            [:ice_servers, :negotiation_timeout_ms]
          ),
          :owner,
          self()
        )
      )

    {:ok, transport} =
      Transport.start_link(
        peer: peer,
        owner: self(),
        max_queue_packets: Keyword.get(opts, :max_queue_packets, 100)
      )

    {:ok, session} =
      AudioFlow.start_session(
        Keyword.merge(Keyword.fetch!(opts, :session),
          owner: self(),
          output: {Transport, transport}
        )
      )

    Process.monitor(session)

    {:ok,
     %{
       owner: owner,
       peer: peer,
       transport: transport,
       session: session,
       input: %{input | session: session},
       track: nil,
       ssrc: nil
     }}
  end

  @impl true
  def handle_call(:offer, _, s), do: {:reply, WebRTC.offer(s.peer), s}
  def handle_call({:signal, message}, _, s), do: {:reply, WebRTC.signal(s.peer, message), s}
  def handle_call(:cancel, _, s), do: {:reply, AudioFlow.cancel(s.session), s}
  def handle_call({:submit, input}, _, s), do: {:reply, AudioFlow.submit(s.session, input), s}

  @impl true
  def handle_info(
        {WebRTC, peer, {:media, {:track, %{kind: :audio, id: id}}}},
        %{peer: peer, track: nil} = s
      ),
      do: accept_track(id, s)

  def handle_info({WebRTC, peer, {:media, {:track, %{kind: :audio}}}}, %{peer: peer} = s),
    do: fail(:multiple_audio_tracks, s)

  def handle_info(
        {WebRTC, peer, {:media, {:rtp, track, nil, packet}}},
        %{peer: peer, track: track} = s
      )
      when track != nil do
    cond do
      packet.payload_type != 0 or byte_size(packet.payload) != 160 -> fail(:unsupported_rtp, s)
      s.ssrc != nil and s.ssrc != packet.ssrc -> fail(:ssrc_changed, s)
      true -> input(RtpInput.push(s.input, packet), %{s | ssrc: packet.ssrc})
    end
  end

  def handle_info({WebRTC, peer, {:media, {:rtp, _, _, _}}}, %{peer: peer} = s),
    do: fail(:unexpected_rtp_track, s)

  def handle_info({WebRTC, peer, {:signal, message}}, %{peer: peer} = s) do
    notify(s, {:signal, message})
    {:noreply, s}
  end

  def handle_info({WebRTC, peer, :connected}, %{peer: peer} = s) do
    notify(s, :connected)
    {:noreply, s}
  end

  def handle_info({AudioFlow, session, turn, event}, %{session: session} = s) do
    notify(s, {:session, turn, event})
    {:noreply, s}
  end

  def handle_info({:gap, token}, s), do: input(RtpInput.gap(s.input, token), s)

  def handle_info({Transport, transport, {:error, reason}}, %{transport: transport} = s),
    do: fail({:output, reason}, s)

  def handle_info({:DOWN, _, :process, _, _}, s), do: {:stop, :normal, s}
  def handle_info({:EXIT, _, _}, s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  defp input({:ok, input}, s), do: {:noreply, %{s | input: input}}
  defp input({:error, reason}, s), do: fail(reason, s)

  defp accept_track(id, s) do
    case WebRTC.track_codecs(s.peer, id) do
      [
        %ExWebRTC.RTPCodecParameters{
          payload_type: 0,
          mime_type: mime,
          clock_rate: 8000,
          channels: channels
        }
      ]
      when channels in [nil, 1] ->
        if String.downcase(mime) == "audio/pcmu",
          do:
            {:noreply,
             %{s | track: id, input: RtpInput.restart(s.input, PCMUDecoder.new(), 8000)}},
          else: fail(:unsupported_audio_codec, s)

      _ ->
        fail(:unsupported_audio_codec, s)
    end
  end

  @impl true
  def terminate(_, s) do
    RtpInput.stop(s.input)
    # Release a Session possibly waiting for Output.finish before stopping it.
    safely(fn -> GenServer.stop(s.transport) end)
    safely(fn -> AudioFlow.stop_session(s.session) end)
    safely(fn -> WebRTC.stop(s.peer) end)
    :ok
  end

  defp fail(reason, s) do
    notify(s, {:error, reason})
    {:stop, :normal, s}
  end

  defp notify(s, event), do: send(s.owner, {__MODULE__, self(), event})

  defp safely(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end
end
