defmodule AudioFlowUI.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: AudioFlowUI.PubSub},
      {Task.Supervisor, name: AudioFlowUI.Tasks},
      {Sake, secret_key_base: {AudioFlowUIWeb.Endpoint, :config, [:secret_key_base]}},
      AudioFlowUI.Graphs,
      AudioFlowUIWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AudioFlowUI.Supervisor)
  end
end
