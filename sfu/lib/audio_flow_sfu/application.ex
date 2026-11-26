defmodule AudioFlowSFU.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    configure_from_env()

    children =
      [
        {Registry, keys: :unique, name: AudioFlowSFU.Registry},
        {DynamicSupervisor, name: AudioFlowSFU.Rooms, strategy: :one_for_one},
        {DynamicSupervisor, name: AudioFlowSFU.Participants, strategy: :one_for_one}
      ] ++ endpoint()

    Supervisor.start_link(children, strategy: :one_for_one, name: AudioFlowSFU.Supervisor)
  end

  # Environment variables override the application environment, so a
  # release needs no runtime.exs:
  #   AUDIOFLOW_SFU_PORT        HTTP port for /ws and /rtc/v1
  #   AUDIOFLOW_SFU_API_KEY     API key (JWT `iss`)
  #   AUDIOFLOW_SFU_API_SECRET  HS256 secret for that key
  #   AUDIOFLOW_SFU_ICE_SERVERS comma-separated STUN/TURN URLs
  defp configure_from_env do
    if port = System.get_env("AUDIOFLOW_SFU_PORT"),
      do: put(:port, String.to_integer(port))

    with key when is_binary(key) <- System.get_env("AUDIOFLOW_SFU_API_KEY"),
         secret when is_binary(secret) <- System.get_env("AUDIOFLOW_SFU_API_SECRET"),
         do: put(:api_keys, %{key => secret})

    if urls = System.get_env("AUDIOFLOW_SFU_ICE_SERVERS"),
      do: put(:ice_servers, [%{urls: String.split(urls, ",", trim: true)}])
  end

  defp put(key, value), do: Application.put_env(:audio_flow_sfu, key, value)

  defp endpoint do
    case Application.get_env(:audio_flow_sfu, :port) do
      nil -> []
      port -> [{Bandit, plug: AudioFlowSFU.Router, port: port}]
    end
  end
end
