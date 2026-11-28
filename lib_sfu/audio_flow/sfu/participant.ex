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
  to 16 kHz and feeds VoiceInput. Speech start cancels output. The RTP
  timestamps place the audio on a clock: a lost packet (after
  `:gap_timeout_ms`), a burst loss beyond `:reorder_window`, and the packets
  that Opus DTX leaves out all become silence (at most one second per gap).
  The call does not end.

  Events for the owner are `{AudioFlow.SFU.Participant, pid, event}`:
  `{:joined, join}`, `{:session, turn, event}`, `{:utterance, reason}`,
  `{:participant_joined | :participant_updated | :participant_left, info}`,
  `{:error, reason}` and `{:closed, reason}`.
  """
  use GenServer
  alias AudioFlow.SFU.OpusDecoder
  alias AudioFlow.SFU.Transport
  alias AudioFlow.Transport.PCMUDecoder
  alias AudioFlow.Transport.RtpInput

  @vsn 1

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

    input =
      RtpInput.new(
        Keyword.take(options, [:voice_input, :endpoint_options]) ++
          [
            owner: owner,
            tag: __MODULE__,
            vad: Keyword.fetch!(options, :vad),
            reorder_window: Keyword.get(options, :reorder_window, 32),
            gap_timeout_ms: Keyword.get(options, :gap_timeout_ms, 200),
            loss: :silence
          ]
      )

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
        input: %{input | session: session},
        members: Map.new(join.others, &{&1.sid, &1}),
        source: nil
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
      do: input(RtpInput.push(s.input, rtp), s),
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

  def handle_info({:gap, token}, s), do: input(RtpInput.gap(s.input, token), s)

  def handle_info({:DOWN, _, :process, pid, reason}, %{join: %{participant: pid}} = s) do
    notify(s.owner, {:error, {:sfu_participant_down, reason}})
    {:stop, :normal, s}
  end

  def handle_info({:DOWN, _, :process, _, _}, s), do: {:stop, :normal, s}
  def handle_info({:EXIT, _, _}, s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    RtpInput.stop(s.input)
    # Release a session that may wait in Output.finish before stopping it.
    safely(fn -> GenServer.stop(s.transport) end)
    safely(fn -> AudioFlow.stop_session(s.session) end)
    :ok
  end

  ## Listening

  # The first audio track of a member that is not an agent. A member update
  # (such as a mute) keeps the stream state of a track that stays the same.
  defp choose_source(s) do
    candidate =
      s.members
      |> Map.values()
      |> Enum.reject(&(&1.kind == :agent))
      |> Enum.sort_by(& &1.joined_at)
      |> Enum.find_value(fn info -> List.first(info.tracks) end)

    cond do
      same_track?(candidate, s.source) ->
        %{s | source: candidate}

      candidate != nil and candidate.mime_type == "audio/opus" ->
        %{s | source: candidate, input: RtpInput.restart(s.input, OpusDecoder.new(), 48_000)}

      true ->
        %{s | source: candidate, input: RtpInput.restart(s.input, PCMUDecoder.new(), 8000)}
    end
  end

  defp same_track?(nil, nil), do: true
  defp same_track?(%{sid: sid}, %{sid: sid}), do: true
  defp same_track?(_, _), do: false

  defp input({:ok, input}, s), do: {:noreply, %{s | input: input}}
  defp input({:error, reason}, s), do: fail(reason, s)

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
