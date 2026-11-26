defmodule AudioFlow.SFU.Participant do
  @moduledoc """
  Runs an `AudioFlow.Session` as a native participant in an AudioFlow SFU room.
  Enable with `AUDIOFLOW_SFU=1`.

  The SFU runs on its own node (`:sfu`, default `node()`), so this node can
  restart while the call stays connected. The participant joins with `:erpc`
  and exchanges plain messages with the SFU; it needs no SFU code.

  Options: `:room`, `:identity` and `:session` (session options) are
  required, with `:vad` (a 16 kHz VoiceInput detector tuple). Optional:
  `:sfu`, `:owner` (default caller), `:name`, `:voice_input`,
  `:gap_timeout_ms` (200), `:reorder_window` (32), `:max_queue_packets` (100),
  and `:join` (extra `AudioFlowSFU.Native.join/4` options, such as
  `:resume_token` to take back a participant after a restart).

  The participant listens to one remote audio track at a time: the first
  track of a member that is not an agent. It decodes Opus or PCMU, resamples
  to 16 kHz and feeds VoiceInput. Speech start cancels output. A lost packet
  becomes 20 ms of silence after `:gap_timeout_ms`; the call does not end.

  Events for the owner are `{AudioFlow.SFU.Participant, pid, event}`:
  `{:joined, join}`, `{:session, turn, event}`, `{:utterance, reason}`,
  `{:participant_joined | :participant_updated | :participant_left, info}`,
  `{:error, reason}` and `{:closed, reason}`.
  """
  use GenServer
  alias AudioFlow.Audio
  alias AudioFlow.Resampler
  alias AudioFlow.RTP.Reorder
  alias AudioFlow.SFU.Transport
  alias AudioFlow.Telephony.MuLaw
  alias AudioFlow.Telephony.RateConverter
  alias AudioFlow.VoiceInput
  alias Membrane.Opus.Decoder.Native, as: Decoder

  @vsn 1
  @silence_20ms :binary.copy(<<0, 0>>, 320)

  def start_link(options),
    do: GenServer.start_link(__MODULE__, Keyword.put_new(options, :owner, self()))

  def session(pid), do: GenServer.call(pid, :session)
  @doc "The join result: SFU participant PID, info and resume token."
  def join_info(pid), do: GenServer.call(pid, :join_info)
  def stop(pid), do: GenServer.stop(pid)

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(options, :owner)
    Process.monitor(owner)
    sfu = Keyword.get(options, :sfu, node())
    room = Keyword.fetch!(options, :room)
    identity = Keyword.fetch!(options, :identity)
    voice = VoiceInput.new(Keyword.fetch!(options, :vad), Keyword.get(options, :voice_input, []))
    unless voice.rate == 16_000, do: raise(ArgumentError, "SFU VAD requires 16 kHz")

    join_options =
      Keyword.merge(
        [name: Keyword.get(options, :name, identity)],
        Keyword.get(options, :join, [])
      )

    with {:ok, join} <- remote(sfu, :join, [room, identity, self(), join_options]),
         {:ok, track} <- own_track(sfu, join) do
      join = %{join | info: %{join.info | tracks: [track]}}
      Process.monitor(join.participant)

      {:ok, transport} =
        Transport.start_link(
          participant: join.participant,
          track: track.sid,
          max_queue_packets: Keyword.get(options, :max_queue_packets, 100)
        )

      {:ok, session} =
        AudioFlow.start_session(
          Keyword.merge(Keyword.fetch!(options, :session),
            owner: self(),
            output: {Transport, transport}
          )
        )

      Process.monitor(session)
      notify(owner, {:joined, join})

      state = %{
        owner: owner,
        sfu: sfu,
        join: join,
        track: track,
        transport: transport,
        session: session,
        voice: voice,
        members: Map.new(join.others, &{&1.sid, &1}),
        source: nil,
        reorder: Reorder.new(Keyword.get(options, :reorder_window, 32)),
        gap_timeout: Keyword.get(options, :gap_timeout_ms, 200),
        gap: nil,
        # For an Opus source: channel count => decoder, set by choose_source/1.
        decoder: nil,
        resampler: nil,
        up: %RateConverter{}
      }

      {:ok, choose_source(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # A resumed participant keeps its published track.
  defp own_track(_sfu, %{info: %{tracks: [track | _]}}), do: {:ok, track}

  defp own_track(sfu, join),
    do: remote(sfu, :publish_track, [join.participant, "audio/opus", "agent"])

  defp remote(sfu, function, arguments) do
    :erpc.call(sfu, AudioFlowSFU.Native, function, arguments, 10_000)
  catch
    :error, {:erpc, reason} -> {:error, {:sfu_unavailable, reason}}
    :exit, reason -> {:error, {:sfu_unavailable, reason}}
  end

  @impl true
  def handle_call(:session, _, s), do: {:reply, s.session, s}
  def handle_call(:join_info, _, s), do: {:reply, s.join, s}

  @impl true
  def handle_info({:audio_flow_sfu, 1, p, {:rtp, sid, rtp}}, %{join: %{participant: p}} = s) do
    if s.source && sid == s.source.sid,
      do: reorder(rtp, s),
      else: {:noreply, s}
  end

  def handle_info({:audio_flow_sfu, 1, p, {event, info}}, %{join: %{participant: p}} = s)
      when event in [:participant_joined, :participant_updated] do
    notify(s.owner, {event, info})
    {:noreply, choose_source(%{s | members: Map.put(s.members, info.sid, info)})}
  end

  def handle_info(
        {:audio_flow_sfu, 1, p, {:participant_left, info}},
        %{join: %{participant: p}} = s
      ) do
    notify(s.owner, {:participant_left, info})
    {:noreply, choose_source(%{s | members: Map.delete(s.members, info.sid)})}
  end

  def handle_info({:audio_flow_sfu, 1, p, {:closed, reason}}, %{join: %{participant: p}} = s) do
    notify(s.owner, {:closed, reason})
    {:stop, :normal, s}
  end

  def handle_info({AudioFlow, session, turn, event}, %{session: session} = s) do
    notify(s.owner, {:session, turn, event})
    {:noreply, s}
  end

  def handle_info({:gap, token}, %{gap: {_, token}} = s) do
    {lost, packets, reorder} = Reorder.skip(s.reorder)
    s = %{s | gap: nil, reorder: reorder}
    s = Enum.reduce(1..lost//1, s, fn _, s -> listen(s, @silence_20ms) end)
    play(packets, s)
  end

  def handle_info({:DOWN, _, :process, pid, reason}, %{join: %{participant: pid}} = s) do
    notify(s.owner, {:error, {:sfu_participant_down, reason}})
    {:stop, :normal, s}
  end

  def handle_info({:DOWN, _, :process, _, _}, s), do: {:stop, :normal, s}
  def handle_info({:EXIT, _, _}, s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    if s.gap, do: Process.cancel_timer(elem(s.gap, 0))
    # Release a session that may wait in Output.finish before stopping it.
    safely(fn -> GenServer.stop(s.transport) end)
    safely(fn -> AudioFlow.stop_session(s.session) end)
    :ok
  end

  ## Listening

  # The first audio track of a member that is not an agent.
  defp choose_source(s) do
    candidate =
      s.members
      |> Map.values()
      |> Enum.reject(&(&1.kind == :agent))
      |> Enum.sort_by(& &1.joined_at)
      |> Enum.find_value(fn info -> List.first(info.tracks) end)

    cond do
      candidate == s.source ->
        s

      candidate != nil and candidate.mime_type == "audio/opus" ->
        %{s | source: candidate, reorder: Reorder.new(s.reorder.window)}
        |> Map.merge(%{decoder: %{}, resampler: Resampler.new(48_000, 16_000)})

      true ->
        %{s | source: candidate, reorder: Reorder.new(s.reorder.window), up: %RateConverter{}}
    end
  end

  defp reorder(rtp, s) do
    case Reorder.push(s.reorder, rtp) do
      {:ok, packets, reorder} -> play(packets, %{s | reorder: reorder})
      {:error, reason} -> fail(reason, s)
    end
  end

  defp play(packets, s) do
    s =
      Enum.reduce(packets, s, fn packet, s ->
        {pcm, s} = decode(s, packet.payload)
        listen(s, pcm)
      end)

    {:noreply, schedule_gap(s)}
  rescue
    error -> fail({:decode, Exception.message(error)}, s)
  end

  defp decode(%{source: %{mime_type: "audio/PCMU"}} = s, payload) do
    {data, up} = RateConverter.up(MuLaw.decode(payload), s.up)
    {data, %{s | up: up}}
  end

  # Browsers can send stereo Opus (`stereo=1`). The TOC byte says how many
  # channels a packet has; a stereo packet is decoded in stereo and mixed down.
  defp decode(s, <<_::5, stereo::1, _::2, _::binary>> = payload) do
    channels = stereo + 1
    decoder = Map.get_lazy(s.decoder, channels, fn -> Decoder.create(48_000, channels) end)
    pcm = Decoder.decode_packet(decoder, payload)
    pcm = if channels == 2, do: downmix(pcm), else: pcm
    {Resampler.push(s.resampler, pcm), %{s | decoder: Map.put(s.decoder, channels, decoder)}}
  end

  defp decode(s, _payload), do: {<<>>, s}

  defp downmix(pcm) do
    for <<l::little-signed-16, r::little-signed-16 <- pcm>>,
      into: <<>>,
      do: <<div(l + r, 2)::little-signed-16>>
  end

  defp listen(s, <<>>), do: s

  defp listen(s, pcm) do
    {events, voice} = VoiceInput.push(s.voice, %Audio{data: pcm, sample_rate: 16_000})
    Enum.each(events, &voice_event(s, &1))
    %{s | voice: voice}
  end

  defp voice_event(s, :speech_started), do: AudioFlow.cancel(s.session)

  defp voice_event(s, {:utterance, audio, reason}) do
    notify(s.owner, {:utterance, reason})

    case AudioFlow.submit(s.session, audio) do
      {:ok, _} -> :ok
      {:error, reason} -> notify(s.owner, {:error, {:submit, reason}})
    end
  end

  defp voice_event(_s, _event), do: :ok

  defp schedule_gap(s) do
    cond do
      not Reorder.waiting?(s.reorder) ->
        if s.gap, do: Process.cancel_timer(elem(s.gap, 0))
        %{s | gap: nil}

      s.gap == nil ->
        token = make_ref()
        %{s | gap: {Process.send_after(self(), {:gap, token}, s.gap_timeout), token}}

      true ->
        s
    end
  end

  defp fail(reason, s) do
    notify(s.owner, {:error, reason})
    {:stop, :normal, s}
  end

  defp notify(owner, event), do: send(owner, {__MODULE__, self(), event})

  defp safely(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end
end
