defmodule AudioFlowUIWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Sake.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AudioFlowUIWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :mcp do
    plug AudioFlowUIWeb.MCPToken
  end

  scope "/" do
    pipe_through :mcp
    # Without `origins:`, Sake refuses browser requests, which blocks DNS rebinding.
    sake_endpoint "/mcp", server: AudioFlowUI.MCP
  end

  scope "/" do
    pipe_through :browser
    live "/", AudioFlowUIWeb.GraphsLive
    live "/graphs/:id", AudioFlowUIWeb.GraphLive
  end
end
