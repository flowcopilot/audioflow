import Config

# Local settings. The dashboard and its MCP endpoint listen on the loopback interface only.
config :audio_flow_ui, AudioFlowUIWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4100"))],
  check_origin: ["//localhost", "//127.0.0.1"],
  secret_key_base: String.duplicate("audioflow_ui_local_development_only", 2),
  live_view: [signing_salt: "audioflow_ui"],
  pubsub_server: AudioFlowUI.PubSub

config :phoenix, :json_library, Jason
config :logger, level: String.to_existing_atom(System.get_env("LOG_LEVEL", "info"))
config :logger, :default_formatter, format: "$time [$level] $message\n"

case config_env() do
  :dev ->
    config :audio_flow_ui, AudioFlowUIWeb.Endpoint,
      code_reloader: true,
      debug_errors: true,
      live_reload: [
        web_console_logger: true,
        patterns: [~r"priv/static/assets/.*(js|css)$", ~r"lib/audio_flow_ui_web/.*ex$"]
      ]

  :test ->
    config :audio_flow_ui, AudioFlowUIWeb.Endpoint, server: false

    config :audio_flow_ui,
      data_dir: Path.join(System.tmp_dir!(), "audioflow_ui_test"),
      seed: false

    config :logger, level: :warning

  :prod ->
    :ok
end
