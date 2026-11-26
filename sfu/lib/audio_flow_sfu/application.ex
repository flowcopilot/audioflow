defmodule AudioFlowSFU.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: AudioFlowSFU.Registry},
        {DynamicSupervisor, name: AudioFlowSFU.Rooms, strategy: :one_for_one},
        {DynamicSupervisor, name: AudioFlowSFU.Participants, strategy: :one_for_one}
      ] ++ endpoint()

    Supervisor.start_link(children, strategy: :one_for_one, name: AudioFlowSFU.Supervisor)
  end

  defp endpoint do
    case Application.get_env(:audio_flow_sfu, :port) do
      nil -> []
      port -> [{Bandit, plug: AudioFlowSFU.Router, port: port}]
    end
  end
end
