defmodule AudioFlowUI.ProviderGraphTest do
  use ExUnit.Case, async: false

  alias Plug.Conn

  defmodule Endpoint do
    def init(options), do: options

    def call(conn, {owner, status}) do
      {:ok, body, conn} = Conn.read_body(conn)
      send(owner, {:provider_request, conn.req_headers, Jason.decode!(body), conn.query_string})

      conn
      |> Conn.put_resp_content_type("audio/pcm")
      |> Conn.send_resp(status, <<1, 0, 2, 0>>)
    end
  end

  setup do
    original = System.get_env("ELEVENLABS_API_KEY")
    endpoints = Application.get_env(:audio_flow, :speech_provider_endpoints)
    System.put_env("ELEVENLABS_API_KEY", "fixture-key")

    on_exit(fn ->
      if original,
        do: System.put_env("ELEVENLABS_API_KEY", original),
        else: System.delete_env("ELEVENLABS_API_KEY")

      if endpoints,
        do: Application.put_env(:audio_flow, :speech_provider_endpoints, endpoints),
        else: Application.delete_env(:audio_flow, :speech_provider_endpoints)
    end)

    :ok
  end

  defp graph(status) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {Endpoint, {self(), status}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)

    Application.put_env(:audio_flow, :speech_provider_endpoints, %{
      "elevenlabs.tts" => "http://127.0.0.1:#{port}/tts"
    })

    AudioFlowUI.Examples.starter("tts")
    |> put_in(["nodes", Access.at(1), "options", "voice_id"], "fixture-voice")
    |> put_in(["nodes", Access.at(1), "options", "language"], "ro")
  end

  test "remote TTS graph sends real HTTP with server key and selected language; returns PCM counts" do
    assert {:ok,
            %{
              "status" => "done",
              "events" => [
                %{"type" => "audio", "bytes" => 4, "sample_rate" => 24_000}
              ]
            }} = AudioFlowUI.Runs.run_text(graph(200), "Salut")

    assert_receive {:provider_request, headers,
                    %{
                      "text" => "Salut",
                      "language_code" => "ro",
                      "model_id" => "eleven_multilingual_v2"
                    }, query}

    assert {"xi-api-key", "fixture-key"} in headers
    assert URI.decode_query(query)["output_format"] == "pcm_24000"
  end

  test "remote failure produces a graph error without exposing provider key or body" do
    assert {:ok, %{"status" => "error"} = result} = AudioFlowUI.Runs.run_text(graph(401), "Salut")
    refute Jason.encode!(result) =~ "fixture-key"
  end
end
