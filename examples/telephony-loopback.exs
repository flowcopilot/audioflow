# Run: mix run examples/telephony-loopback.exs
# Offline wire demonstration only: the detector below marks all PCM as speech,
# and Demo adapters return silent PCM. No provider call or inference is made.
defmodule AudioFlow.TelephonyExamplePlug.AlwaysSpeechDetector do
  @behaviour AudioFlow.VoiceDetector
  @impl true
  def init(_options), do: {512, 16_000, nil}
  @impl true
  def predict(_audio, state), do: {0.9, state}
end

defmodule AudioFlow.TelephonyExamplePlug do
  def init(provider), do: provider

  def call(conn, provider) do
    conn
    |> WebSockAdapter.upgrade(
      AudioFlow.Telephony.WebSocket,
      [
        provider: provider,
        session: AudioFlow.Adapters.Demo.options(),
        vad: {AudioFlow.TelephonyExamplePlug.AlwaysSpeechDetector, []},
        endpoint_options: [pre_roll_ms: 0, max_utterance_ms: 96]
      ],
      []
    )
    |> Plug.Conn.halt()
  end
end

# The client is a dependency-free test helper. MIX_ENV=test compiles it already.
unless Code.ensure_loaded?(AudioFlow.Test.WebSocketClient),
  do: Code.require_file("../test/support/web_socket_client.ex", __DIR__)

alias AudioFlow.Test.WebSocketClient, as: Client

for provider <- [:twilio, :telnyx] do
  {:ok, server} =
    Bandit.start_link(
      plug: {AudioFlow.TelephonyExamplePlug, provider},
      port: 0,
      ip: {127, 0, 0, 1}
    )

  {:ok, {_, port}} = ThousandIsland.listener_info(server)
  socket = Client.connect(port)

  start =
    case provider do
      :twilio ->
        %{
          event: "start",
          streamSid: "fixture",
          start: %{
            streamSid: "fixture",
            mediaFormat: %{encoding: "audio/x-mulaw", sampleRate: 8000, channels: 1}
          }
        }

      :telnyx ->
        %{
          event: "start",
          stream_id: "fixture",
          start: %{
            media_format: %{encoding: "PCMU", sample_rate: 8000, channels: 1}
          }
        }
    end

  Client.send_json(socket, start)
  key = if provider == :twilio, do: :streamSid, else: :stream_id
  order = if provider == :twilio, do: [1, 2], else: [2, 2, 1]

  for chunk <- order do
    Client.send_json(
      socket,
      Map.put(
        %{
          event: "media",
          sequence_number: Integer.to_string(chunk + 1),
          media: %{
            track: "inbound",
            chunk: Integer.to_string(chunk),
            timestamp: Integer.to_string((chunk - 1) * 50),
            payload: Base.encode64(:binary.copy(<<255>>, 400))
          }
        },
        key,
        "fixture"
      )
    )
  end

  for _ <- 1..5 do
    {:json, %{"event" => "media", "media" => %{"payload" => payload}}} = Client.recv(socket)
    160 = byte_size(Base.decode64!(payload))
  end

  Client.send_json(socket, Map.put(%{event: "stop"}, key, "fixture"))
  {:close, _} = Client.recv(socket)
  Client.close(socket)
  GenServer.stop(server)
  IO.puts("#{provider}: start/media/stop passed; received five paced PCMU packets")
end
