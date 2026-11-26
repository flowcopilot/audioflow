defmodule AudioFlowSFU.Signaling.JSON do
  @moduledoc """
  AudioFlow signaling protocol v0: JSON text frames over a WebSocket at
  `/ws?access_token=<jwt>`.

  Server messages: `join` (`participant`, `others`, `ice_servers`,
  `resume_token`, `resumed`), `offer`
  and `answer` (`sdp`, `tracks`: SDP mid => track SID), `candidate`,
  `connected`, `track_published` (`track`), `participant_joined`,
  `participant_updated`, `participant_left` (`participant`), `pong`,
  `error` (`reason`) and `closed` (`reason`).

  Client messages: `answer` and `offer` (`sdp`), `candidate` (`candidate`),
  `mute` (`track`, `muted`), `ice_restart`, `ping` and `leave`.

  A dropped socket does not end the session. Connect again within the away
  timeout with `&resume=<resume_token>` to keep the same participant, its
  tracks and its subscriptions; the server sends the pending offer again.
  Only `leave` ends the session at once.

  The server makes the first offer. On glare (`error` with reason `glare`)
  the client rolls back its offer and answers the server offer.
  """
  @behaviour WebSock
  alias AudioFlowSFU.Participant
  alias AudioFlowSFU.Participant.WebRTC

  @max_frame 131_072

  @impl true
  def init(%{grants: grants} = options) do
    result =
      case options do
        %{resume: token} when is_binary(token) -> WebRTC.resume(token, grants.identity, self())
        _ -> WebRTC.start(grants, owner: self(), ice_servers: Map.get(options, :ice_servers, []))
      end

    case result do
      {:ok, participant, join} ->
        Process.monitor(participant)
        join = Map.merge(join, %{type: :join, resumed: Map.has_key?(options, :resume)})
        {:push, frame(join), %{participant: participant}}

      {:error, reason} ->
        {:stop, :normal, {1008, to_string(reason)}, %{participant: nil}}
    end
  end

  @impl true
  def handle_in({data, opcode: :text}, state) when byte_size(data) <= @max_frame do
    case JSON.decode(data) do
      {:ok, %{"type" => type} = message} -> command(type, message, state)
      _ -> error(:invalid_message, state)
    end
  end

  def handle_in(_, state), do: error(:invalid_message, state)

  defp command("answer", message, state),
    do: reply(WebRTC.answer(state.participant, message), state)

  defp command("offer", message, state) do
    case WebRTC.offer(state.participant, message) do
      {:ok, answer, mids} ->
        {:push, frame(Map.merge(answer, %{type: :answer, tracks: mids})), state}

      error ->
        reply(error, state)
    end
  end

  defp command("candidate", %{"candidate" => nil}, state), do: {:ok, state}

  defp command("candidate", %{"candidate" => candidate}, state) when is_map(candidate),
    do: reply(WebRTC.candidate(state.participant, candidate), state)

  defp command("mute", %{"track" => sid, "muted" => muted}, state)
       when is_binary(sid) and is_boolean(muted),
       do: reply(WebRTC.mute(state.participant, sid, muted), state)

  defp command("ice_restart", _, state),
    do: reply(WebRTC.restart_ice(state.participant), state)

  defp command("ping", _, state), do: {:push, frame(%{type: :pong}), state}

  defp command("leave", _, state) do
    WebRTC.leave(state.participant)
    {:stop, :normal, 1000, state}
  end

  defp command(_, _, state), do: error(:invalid_message, state)

  defp reply(:ok, state), do: {:ok, state}
  defp reply({:error, reason}, state), do: error(reason, state)

  defp error(reason, state), do: {:push, frame(%{type: :error, reason: reason}), state}

  @impl true
  def handle_info({Participant, pid, event}, %{participant: pid} = state),
    do: event(event, state)

  def handle_info({:DOWN, _, :process, pid, _}, %{participant: pid} = state),
    do: {:stop, :normal, 1000, state}

  def handle_info(_, state), do: {:ok, state}

  defp event({:offer, description, mids}, state),
    do: {:push, frame(Map.merge(description, %{type: :offer, tracks: mids})), state}

  defp event({:candidate, candidate}, state),
    do: {:push, frame(%{type: :candidate, candidate: candidate}), state}

  defp event(:connected, state), do: {:push, frame(%{type: :connected}), state}

  defp event({:track_published, track}, state),
    do: {:push, frame(%{type: :track_published, track: track}), state}

  defp event({event, info}, state)
       when event in [:participant_joined, :participant_updated, :participant_left],
       do: {:push, frame(%{type: event, participant: info}), state}

  defp event({:closed, reason}, state) do
    {:stop, :normal, 1000, [frame(%{type: :closed, reason: inspect(reason)})], state}
  end

  defp event(_, state), do: {:ok, state}

  # A closed socket does not leave: the participant waits for a resume.
  @impl true
  def terminate(_reason, _state), do: :ok

  defp frame(message), do: {:text, JSON.encode!(message)}
end
