defmodule AudioFlowSFU.TestClient do
  @moduledoc false
  # A WebRTC client for tests: an ExWebRTC peer that answers server offers,
  # trickles ICE, publishes one Opus track and reports received RTP.
  use GenServer
  alias AudioFlowSFU.Participant
  alias AudioFlowSFU.Participant.WebRTC
  alias ExWebRTC.ICECandidate
  alias ExWebRTC.MediaStreamTrack
  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription

  def grants(room, identity, overrides \\ %{}) do
    Map.merge(
      %{
        identity: identity,
        name: identity,
        metadata: "",
        kind: :standard,
        room: room,
        can_publish: true,
        can_subscribe: true,
        can_publish_data: true
      },
      overrides
    )
  end

  @doc "Options: grant overrides, and `:options` for the participant (`away_timeout_ms`)."
  def start(room, identity, options \\ []) do
    GenServer.start(__MODULE__, {grants(room, identity, Map.new(options)), self()})
  end

  def participant(client), do: GenServer.call(client, :participant)
  def join_info(client), do: GenServer.call(client, :join_info)

  @doc """
  Sends one RTP packet on the published track. Sequence numbers increase per
  client: SRTP refuses to send a sequence number twice.
  """
  def send_audio(client, payload), do: GenServer.call(client, {:send_audio, payload})

  def stop(client), do: GenServer.stop(client)

  @doc "Kills the signaling relay, as when a client socket drops."
  def drop_signal(client), do: GenServer.call(client, :drop_signal)

  @doc "Resumes the session with a new relay and the resume token."
  def resume(client), do: GenServer.call(client, :resume)

  @impl true
  def init({grants, test}) do
    {:ok, pc} = PeerConnection.start_link()
    relay = relay(self())
    options = Keyword.take(Map.get(grants, :options, []), [:away_timeout_ms])

    case WebRTC.start(Map.delete(grants, :options), Keyword.put(options, :owner, relay)) do
      {:ok, participant, join} ->
        Process.monitor(participant)

        {:ok,
         %{
           test: test,
           relay: relay,
           identity: grants.identity,
           pc: pc,
           participant: participant,
           join: join,
           track: nil,
           sequence: 1,
           publish: grants.can_publish
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:participant, _, s), do: {:reply, s.participant, s}
  def handle_call(:join_info, _, s), do: {:reply, s.join, s}

  def handle_call(:drop_signal, _, s) do
    Process.exit(s.relay, :kill)
    {:reply, :ok, %{s | relay: nil}}
  end

  def handle_call(:resume, _, s) do
    relay = relay(self())

    case WebRTC.resume(s.join.resume_token, s.identity, relay) do
      {:ok, pid, join} -> {:reply, {:ok, join}, %{s | relay: relay, participant: pid}}
      error -> {:reply, error, s}
    end
  end

  def handle_call({:send_audio, payload}, _, s) do
    sequence = rem(s.sequence, 65_536)
    packet = ExRTP.Packet.new(payload, sequence_number: sequence, timestamp: s.sequence * 960)
    {:reply, PeerConnection.send_rtp(s.pc, s.track.id, packet), %{s | sequence: s.sequence + 1}}
  end

  @impl true
  def handle_info({Participant, pid, {:offer, json, mids}}, %{participant: pid} = s) do
    :ok = PeerConnection.set_remote_description(s.pc, SessionDescription.from_json(json))

    s =
      if s.publish and s.track == nil do
        track = MediaStreamTrack.new(:audio)
        {:ok, _} = PeerConnection.add_track(s.pc, track)
        %{s | track: track}
      else
        s
      end

    {:ok, answer} = PeerConnection.create_answer(s.pc)
    :ok = PeerConnection.set_local_description(s.pc, answer)
    WebRTC.answer(pid, SessionDescription.to_json(answer))
    send(s.test, {:client, self(), {:offer_sdp, json["sdp"]}})
    send(s.test, {:client, self(), {:offer, mids}})
    {:noreply, s}
  catch
    # The participant stopped while the client answered.
    :exit, _ -> {:noreply, s}
  end

  def handle_info({Participant, pid, {:candidate, json}}, %{participant: pid} = s) do
    PeerConnection.add_ice_candidate(s.pc, ICECandidate.from_json(json))
    {:noreply, s}
  end

  def handle_info({Participant, pid, event}, %{participant: pid} = s) do
    send(s.test, {:client, self(), event})
    {:noreply, s}
  end

  def handle_info({:ex_webrtc, pc, {:ice_candidate, candidate}}, %{pc: pc} = s) do
    WebRTC.candidate(s.participant, ICECandidate.to_json(candidate))
    {:noreply, s}
  catch
    :exit, _ -> {:noreply, s}
  end

  def handle_info({:ex_webrtc, pc, {:rtp, _id, _rid, packet}}, %{pc: pc} = s) do
    send(s.test, {:client, self(), {:rtp, packet}})
    {:noreply, s}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, %{pc: pc} = s) do
    send(s.test, {:client, self(), :client_connected})
    {:noreply, s}
  end

  def handle_info({:DOWN, _, :process, pid, reason}, %{participant: pid} = s) do
    send(s.test, {:client, self(), {:participant_down, reason}})
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  # The participant owner: forwards participant events to the client.
  defp relay(client) do
    spawn(fn -> relay_loop(client) end)
  end

  defp relay_loop(client) do
    receive do
      message ->
        send(client, message)
        relay_loop(client)
    end
  end
end
