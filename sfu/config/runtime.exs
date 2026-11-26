import Config

# Environment variables for releases and the compatibility tests:
#   AUDIOFLOW_SFU_PORT        HTTP port for /ws and /rtc/v1
#   AUDIOFLOW_SFU_API_KEY     API key (JWT `iss`)
#   AUDIOFLOW_SFU_API_SECRET  HS256 secret for that key
#   AUDIOFLOW_SFU_ICE_SERVERS comma-separated STUN/TURN URLs
if port = System.get_env("AUDIOFLOW_SFU_PORT"),
  do: config(:audio_flow_sfu, port: String.to_integer(port))

with key when is_binary(key) <- System.get_env("AUDIOFLOW_SFU_API_KEY"),
     secret when is_binary(secret) <- System.get_env("AUDIOFLOW_SFU_API_SECRET") do
  config :audio_flow_sfu, api_keys: %{key => secret}
end

if urls = System.get_env("AUDIOFLOW_SFU_ICE_SERVERS"),
  do: config(:audio_flow_sfu, ice_servers: [%{urls: String.split(urls, ",", trim: true)}])
