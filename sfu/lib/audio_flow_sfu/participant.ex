defmodule AudioFlowSFU.Participant do
  @moduledoc """
  Shared participant model and the messages between participant processes.

  Participant info is a map with `:sid`, `:identity`, `:name`, `:metadata`,
  `:kind`, `:state` (`:active` or `:away`), `:joined_at`, `:version`,
  `:permission` and `:tracks`. A track is a map
  with `:sid`, `:type` (`:audio`), `:source`, `:name`, `:mime_type` and
  `:muted`. The signaling modules encode these maps on the wire.

  Participants forward media directly to each other:

  - `{AudioFlowSFU.Participant, :subscribe, track_sid, pid}` asks a publisher
    to send a track to `pid`.
  - `{AudioFlowSFU.Participant, :unsubscribe, track_sid, pid}` stops it.
  - `{AudioFlowSFU.Participant, :rtp, track_sid, packet}` carries one
    `ExRTP.Packet`.

  Events for the owner of a participant (a signaling socket or an agent) are
  `{AudioFlowSFU.Participant, pid, event}`.
  """

  @doc "A new server ID with a LiveKit-style prefix, such as `PA_` or `TR_`."
  def sid(prefix) do
    prefix <> "_" <> Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
  end

  def info(grants) do
    %{
      sid: sid("PA"),
      identity: grants.identity,
      name: grants.name,
      metadata: grants.metadata,
      kind: grants.kind,
      state: :active,
      joined_at: System.system_time(:second),
      # Increases with each change; LiveKit clients ignore older versions.
      version: 1,
      permission: %{
        can_publish: grants.can_publish,
        can_subscribe: grants.can_subscribe,
        can_publish_data: grants.can_publish_data
      },
      tracks: []
    }
  end

  def track(mime_type, name \\ "microphone") do
    %{
      sid: sid("TR"),
      type: :audio,
      source: :microphone,
      name: name,
      mime_type: mime_type,
      muted: false
    }
  end

  def subscribe(publisher, track_sid),
    do: send(publisher, {__MODULE__, :subscribe, track_sid, self()})

  def unsubscribe(publisher, track_sid),
    do: send(publisher, {__MODULE__, :unsubscribe, track_sid, self()})

  @doc """
  Sends one packet to each subscriber. A subscriber on a busy distribution
  connection loses the packet: late audio has no value. Returns the number
  of dropped packets.
  """
  def forward(subscribers, track_sid, packet) do
    message = {__MODULE__, :rtp, track_sid, packet}

    Enum.count(subscribers, fn pid ->
      :erlang.send(pid, message, [:nosuspend]) == :nosuspend
    end)
  end

  @doc "Sends an event to the owner. Events for an absent owner are dropped."
  def notify(nil, _event), do: :ok
  def notify(owner, event), do: send(owner, {__MODULE__, self(), event})
end
