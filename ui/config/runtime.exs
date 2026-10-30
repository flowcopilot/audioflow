import Config

# With a token, the MCP endpoint requires `Authorization: Bearer <token>`.
if token = System.get_env("AUDIOFLOW_UI_TOKEN"), do: config(:audio_flow_ui, :mcp_token, token)
if dir = System.get_env("AUDIOFLOW_UI_DATA"), do: config(:audio_flow_ui, :data_dir, dir)
