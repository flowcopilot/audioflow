defmodule AudioFlow.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Finch,
         name: AudioFlow.HTTPClient,
         pools: %{default: [protocols: [:http1], conn_opts: [transport_opts: [timeout: 5_000]]]}},
        {Task.Supervisor, name: AudioFlow.Tasks},
        {DynamicSupervisor, name: AudioFlow.Sessions, strategy: :one_for_one}
      ] ++ Application.get_env(:audio_flow, :inference_children, [])

    Supervisor.start_link(children, strategy: :one_for_one, name: AudioFlow.Supervisor)
  end
end
