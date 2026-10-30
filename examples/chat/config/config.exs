import Config

# Development settings only. This example is not a production deployment.
config :chat, ChatWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: String.duplicate("audioflow_chat_example_development_only", 2),
  live_view: [signing_salt: "audioflow_chat"],
  pubsub_server: Chat.PubSub,
  live_reload: [
    web_console_logger: true,
    patterns: [~r"priv/static/assets/.*(js|css)$", ~r"lib/chat_web/.*ex$"]
  ]

config :phoenix, :json_library, Jason
# Keep recorded PCM out of any request log.
config :phoenix, :filter_parameters, ["password", "pcm"]
# Debug logs print every LiveView event. Set LOG_LEVEL=debug to see them.
config :logger, level: String.to_existing_atom(System.get_env("LOG_LEVEL", "info"))
config :logger, :default_formatter, format: "$time [$level] $message\n"
