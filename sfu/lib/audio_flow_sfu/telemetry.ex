defmodule AudioFlowSFU.Telemetry do
  @moduledoc """
  `:telemetry` events. Each has `system_time` as its measurement.

  | Event | Metadata |
  | --- | --- |
  | `[:audio_flow_sfu, :room, :start \\| :stop]` | `room` |
  | `[:audio_flow_sfu, :participant, :join \\| :away \\| :resume \\| :leave]` | `room`, `sid`, `identity`, `kind` |
  | `[:audio_flow_sfu, :track, :publish \\| :unpublish]` | `room`, `participant`, `track`, `mime_type` |
  | `[:audio_flow_sfu, :rtp, :dropped]` | `room`, `participant`, `track`; measurement `count` |
  """

  def room(event, room), do: execute([:room, event], %{room: room})

  def participant(event, info, room),
    do:
      execute([:participant, event], %{
        room: room,
        sid: info.sid,
        identity: info.identity,
        kind: info.kind
      })

  def track(event, track, info, room),
    do:
      execute([:track, event], %{
        room: room,
        participant: info.sid,
        track: track.sid,
        mime_type: track.mime_type
      })

  def dropped(0, _track, _info, _room), do: :ok

  def dropped(count, track_sid, info, room) do
    :telemetry.execute(
      [:audio_flow_sfu, :rtp, :dropped],
      %{count: count},
      %{room: room, participant: info.sid, track: track_sid}
    )
  end

  defp execute(event, metadata),
    do:
      :telemetry.execute(
        [:audio_flow_sfu | event],
        %{system_time: System.system_time()},
        metadata
      )
end
