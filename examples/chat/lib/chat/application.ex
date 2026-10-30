defmodule Chat.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Chat.PubSub},
      {Task.Supervisor, name: Chat.Tasks},
      {DynamicSupervisor, name: Chat.Servings},
      Chat.Qwen3ASR,
      Chat.Engine,
      ChatWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Chat.Supervisor)
  end
end
