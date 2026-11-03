Code.require_file("server.ex", __DIR__)
port = String.to_integer(System.get_env("AVATAR_PORT", "4100"))

{:ok, _} =
  Bandit.start_link(
    plug:
      {AvatarExample.Endpoint,
       enabled: System.get_env("AVATAR_LIVE") == "1",
       api_key: System.get_env("LIVEAVATAR_API_KEY"),
       avatar_id: System.get_env("LIVEAVATAR_AVATAR_ID")},
    port: port,
    ip: {127, 0, 0, 1}
  )

IO.puts("Avatar viewer: http://127.0.0.1:#{port} (live calls require AVATAR_LIVE=1)")
