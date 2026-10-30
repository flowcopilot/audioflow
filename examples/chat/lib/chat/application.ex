defmodule Chat.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Chat.Engine,
      {Phoenix.PubSub, name: Chat.PubSub},
      ChatWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Chat.Supervisor)
  end
end
