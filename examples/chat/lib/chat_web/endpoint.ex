defmodule ChatWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :chat

  @session [store: :cookie, key: "_chat_key", signing_salt: "audioflow_chat", same_site: "Lax"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]

  plug Plug.Static, at: "/", from: :chat, gzip: false, only: ~w(assets)

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug Plug.Session, @session
  plug ChatWeb.Router
end
