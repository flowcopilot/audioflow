# Run: MIX_ENV=test mix run examples/telephony-loopback.exs
# Offline wire demonstration only: the test detector marks all PCM as speech,
# and Demo adapters return silent PCM. No provider call or inference is made.
defmodule AudioFlow.TelephonyExamplePlug do
  def init(provider), do: provider

  def call(conn, provider) do
    conn
    |> WebSockAdapter.upgrade(
      AudioFlow.Telephony.WebSocket,
      [
        provider: provider,
        session: AudioFlow.Adapters.Demo.options(),
        vad: {AudioFlow.Test.AlwaysSpeechDetector, []},
        endpoint_options: [pre_roll_ms: 0, max_utterance_ms: 96]
      ],
      []
    )
    |> Plug.Conn.halt()
  end
end

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
            timestamp: Integer.to_string((chunk - 1) * 48),
            payload: Base.encode64(:binary.copy(<<255>>, 384))
          }
        },
        key,
        "fixture"
      )
    )
  end

  for _ <- 1..6 do
    {:json, %{"event" => "media", "media" => %{"payload" => payload}}} = Client.recv(socket)
    160 = byte_size(Base.decode64!(payload))
  end

  Client.send_json(socket, Map.put(%{event: "stop"}, key, "fixture"))
  {:close, _} = Client.recv(socket)
  Client.close(socket)
  GenServer.stop(server)
  IO.puts("#{provider}: start/media/stop passed; received six paced PCMU packets")
end
