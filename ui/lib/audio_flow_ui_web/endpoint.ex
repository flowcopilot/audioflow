defmodule AudioFlowUIWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :audio_flow_ui

  @session [
    store: :cookie,
    key: "_audio_flow_ui_key",
    signing_salt: "audioflow_ui",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session]],
    log: false

  plug Plug.Static, at: "/", from: :audio_flow_ui, gzip: false, only: ~w(assets)

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  # Sake reads the MCP request body itself, so JSON is not parsed here.
  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug Plug.Session, @session
  plug AudioFlowUIWeb.Router
end
