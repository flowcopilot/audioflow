# A voice agent on hosted services: Deepgram speech to text, a ReqLLM chat model,
# Cartesia speech, and the browser page of examples/websocket.exs.
# Run: mix run --no-halt examples/cloud_agent.exs, then open http://127.0.0.1:4000.
# Hold the button to speak. This makes billed provider requests.
# Keys: DEEPGRAM_API_KEY, CARTESIA_API_KEY, CARTESIA_VOICE_ID and the chat
# provider key (ANTHROPIC_API_KEY for the default model). ReqLLM reads the
# Deepgram and chat keys from the environment. With a key missing, this prints
# the usage and exits. AUDIOFLOW_LLM_MODEL picks another ReqLLM model, and
# AUDIOFLOW_WS_PORT changes the port.
model = System.get_env("AUDIOFLOW_LLM_MODEL", "anthropic:claude-sonnet-4-5")
llm_key = String.upcase(hd(String.split(model, ":"))) <> "_API_KEY"
required = ["DEEPGRAM_API_KEY", "CARTESIA_API_KEY", "CARTESIA_VOICE_ID", llm_key]

with [_ | _] = missing <- Enum.reject(required, &System.get_env/1) do
  IO.puts("Missing: #{Enum.join(missing, ", ")}")

  IO.puts(
    "Usage: #{Enum.map_join(required, " ", &"#{&1}=...")} mix run --no-halt examples/cloud_agent.exs"
  )

  System.halt(0)
end

# The page of the WebSocket example. Evaluating its heredoc applies the escapes.
[_, rest] =
  String.split(File.read!(Path.join(__DIR__, "websocket.exs")), "@page \"\"\"\n", parts: 2)

{page, _} = Code.eval_string("\"\"\"\n" <> hd(String.split(rest, "  \"\"\"\n")) <> "  \"\"\"")

session = [
  stt: {AudioFlow.STT.ReqLLM, model: "deepgram:nova-3", language: "en"},
  llm:
    {AudioFlow.Adapters.ReqLLM,
     model: model, system_prompt: AudioFlow.Prompt.default_system(), max_tokens: 200},
  tts:
    {AudioFlow.Adapters.Cartesia,
     model: "sonic-3.6",
     voice_id: System.fetch_env!("CARTESIA_VOICE_ID"),
     api_version: "2026-08-14",
     api_key: fn -> System.fetch_env!("CARTESIA_API_KEY") end},
  history: true
]

defmodule CloudAgent do
  @behaviour Plug

  def init(options), do: options

  def call(%{request_path: "/ws"} = conn, options) do
    conn
    |> WebSockAdapter.upgrade(AudioFlow.WebSocket, [session: options[:session]],
      max_frame_size: 1_000_000
    )
    |> Plug.Conn.halt()
  end

  def call(conn, options) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, options[:page])
  end
end

port = String.to_integer(System.get_env("AUDIOFLOW_WS_PORT", "4000"))

# `mix run` ends the script process after the last line, so the server must not be linked to it.
{:ok, server} =
  Bandit.start_link(
    plug: {CloudAgent, session: session, page: page},
    port: port,
    ip: {127, 0, 0, 1}
  )

Process.unlink(server)
IO.puts("Cloud voice agent on http://127.0.0.1:#{port} (#{model})")
