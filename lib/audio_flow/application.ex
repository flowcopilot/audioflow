defmodule AudioFlow.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Task.Supervisor, name: AudioFlow.Tasks},
        {DynamicSupervisor, name: AudioFlow.Sessions, strategy: :one_for_one}
      ] ++ Application.get_env(:audio_flow, :inference_children, [])

    Supervisor.start_link(children, strategy: :one_for_one, name: AudioFlow.Supervisor)
  end
end
