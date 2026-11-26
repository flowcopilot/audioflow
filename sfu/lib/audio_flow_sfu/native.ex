defmodule AudioFlowSFU.Native do
  @moduledoc """
  Room participants for BEAM processes, such as AudioFlow agents on other
  nodes of a trusted Erlang cluster. Use TLS distribution between hosts.

  An agent calls these functions on the SFU node with `:erpc`, so it does not
  need the SFU code. All media and events are plain terms:

  - Agent to SFU: `send(participant, {:audio_flow_sfu, 1, {:rtp, track_sid, rtp}})`
    for one packet of a track from `publish_track/3`.
  - SFU to agent: `{:audio_flow_sfu, 1, participant, event}`, where `event`
    is `{:rtp, track_sid, rtp}`, `{:participant_joined, info}`,
    `{:participant_updated, info}`, `{:participant_left, info}` or
    `{:closed, reason}`.

  `rtp` is a map with `:sequence_number`, `:timestamp`, `:marker` and
  `:payload`. Participant and track info are the maps described in
  `AudioFlowSFU.Participant`. The participant subscribes to every audio track
  in the room. Packets to a busy distribution connection are dropped.
  """
  alias AudioFlowSFU.Participant.Native

  @doc """
  Joins `room` as `identity` for the `agent` process. Options: `:name`,
  `:metadata`, `:kind` (`:agent`), `:away_timeout_ms`, and `:resume_token`
  to take back a participant whose agent stopped. Returns
  `{:ok, %{participant: pid, info: info, others: [info], resume_token: token}}`.
  """
  def join(room, identity, agent, options \\ [])
      when is_binary(room) and is_binary(identity) and is_pid(agent) do
    case Keyword.get(options, :resume_token) do
      nil -> Native.start(room, identity, agent, options)
      token -> Native.resume(token, identity, agent)
    end
  end

  @doc "Publishes an audio track. Returns `{:ok, track_info}`."
  def publish_track(participant, mime_type \\ "audio/opus", name \\ "agent"),
    do: GenServer.call(participant, {:publish_track, mime_type, name})

  def leave(participant), do: GenServer.call(participant, :leave)
end
