defmodule AudioFlowUI.ProviderGraphTest do
  use ExUnit.Case, async: false

  alias Plug.Conn

  defmodule Endpoint do
    def init(options), do: options

    def call(conn, {owner, status}) do
      {:ok, body, conn} = Conn.read_body(conn)
      send(owner, {:provider_request, conn.req_headers, Jason.decode!(body), conn.query_string})

      if conn.request_path == "/fish" do
        # Canonical zero-length streaming WAV header, followed by PCM.
        header = AudioFlow.Wav.encode(%AudioFlow.Audio{data: <<>>, sample_rate: 44_100})

        conn
        |> Conn.put_resp_content_type("audio/wav")
        |> Conn.send_resp(status, header <> <<1, 0, 2, 0>>)
      else
        conn |> Conn.put_resp_content_type("audio/pcm") |> Conn.send_resp(status, <<1, 0, 2, 0>>)
      end
    end
  end

  setup do
    original = System.get_env("ELEVENLABS_API_KEY")
    original_fish = System.get_env("FISH_AUDIO_API_KEY")
    original_speech = System.get_env("FISH_SPEECH_API_KEY")
    System.delete_env("FISH_SPEECH_API_KEY")
    System.delete_env("FISH_AUDIO_API_KEY")
    endpoints = Application.get_env(:audio_flow, :speech_provider_endpoints)
    System.put_env("ELEVENLABS_API_KEY", "fixture-key")

    on_exit(fn ->
      if original_speech,
        do: System.put_env("FISH_SPEECH_API_KEY", original_speech),
        else: System.delete_env("FISH_SPEECH_API_KEY")

      if original_fish,
        do: System.put_env("FISH_AUDIO_API_KEY", original_fish),
        else: System.delete_env("FISH_AUDIO_API_KEY")

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

  test "Fish Speech graph uses the trusted server endpoint and resolves authentication per run" do
    graph = graph(200)
    endpoints = Application.fetch_env!(:audio_flow, :speech_provider_endpoints)

    Application.put_env(:audio_flow, :speech_provider_endpoints, %{
      "fish_audio.tts" => String.replace(endpoints["elevenlabs.tts"], "/tts", "/fish")
    })

    graph =
      put_in(graph, ["nodes", Access.at(1)], %{
        "id" => graph["nodes"] |> Enum.at(1) |> Map.fetch!("id"),
        "type" => "fish_audio.tts",
        "options" => %{"reference_id" => "narrator"}
      })

    System.put_env("FISH_AUDIO_API_KEY", "hosted-only-key")

    for key <- [nil, "graph-key"] do
      if key, do: System.put_env("FISH_SPEECH_API_KEY", key)

      assert {:ok,
              %{
                "status" => "done",
                "events" => [
                  %{"type" => "audio", "bytes" => 4, "sample_rate" => 44_100}
                ]
              }} = AudioFlowUI.Runs.run_text(graph, "Salut")

      assert_receive {:provider_request, headers,
                      %{
                        "text" => "Salut",
                        "reference_id" => "narrator",
                        "format" => "wav",
                        "streaming" => true
                      }, _}

      assert List.keyfind(headers, "authorization", 0) ==
               if(key, do: {"authorization", "Bearer " <> key}, else: nil)
    end

    Application.delete_env(:audio_flow, :speech_provider_endpoints)
    assert {:error, errors} = AudioFlowUI.Runs.run_text(graph, "Salut")
    assert Enum.any?(errors, &String.contains?(&1, "speech_provider_endpoints"))
    refute_receive {:provider_request, _, _, _}
  end

  test "Fish Speech graph accepts an explicit idle timeout" do
    graph = graph(200)
    endpoints = Application.fetch_env!(:audio_flow, :speech_provider_endpoints)

    Application.put_env(:audio_flow, :speech_provider_endpoints, %{
      "fish_audio.tts" => String.replace(endpoints["elevenlabs.tts"], "/tts", "/fish")
    })

    graph =
      put_in(graph, ["nodes", Access.at(1)], %{
        "id" => graph["nodes"] |> Enum.at(1) |> Map.fetch!("id"),
        "type" => "fish_audio.tts",
        "options" => %{"receive_timeout_ms" => 60_000, "timeout_ms" => 90_000}
      })

    assert {:ok, %{"status" => "done"}} = AudioFlowUI.Runs.run_text(graph, "Salut")
  end

  test "hosted Fish Audio graph requires a key and selects its own PCM rate and model" do
    System.put_env("FISH_SPEECH_API_KEY", "self-hosted-only-key")
    graph = graph(200)
    endpoints = Application.fetch_env!(:audio_flow, :speech_provider_endpoints)

    Application.put_env(:audio_flow, :speech_provider_endpoints, %{
      "fish_audio_api.tts" => endpoints["elevenlabs.tts"]
    })

    graph =
      put_in(graph, ["nodes", Access.at(1)], %{
        "id" => graph["nodes"] |> Enum.at(1) |> Map.fetch!("id"),
        "type" => "fish_audio_api.tts",
        "options" => %{
          "model" => "s2.1-pro",
          "reference_id" => "hosted-voice",
          "sample_rate" => 16_000
        }
      })

    assert {:error, errors} = AudioFlowUI.Runs.run_text(graph, "Salut")
    assert Enum.any?(errors, &String.contains?(&1, "FISH_AUDIO_API_KEY"))
    refute_receive {:provider_request, _, _, _}

    System.put_env("FISH_AUDIO_API_KEY", "api-graph-key")

    assert {:ok,
            %{
              "status" => "done",
              "events" => [
                %{"type" => "audio", "bytes" => 4, "sample_rate" => 16_000}
              ]
            }} = AudioFlowUI.Runs.run_text(graph, "Salut")

    assert_receive {:provider_request, headers,
                    %{
                      "text" => "Salut",
                      "reference_id" => "hosted-voice",
                      "format" => "pcm",
                      "sample_rate" => 16_000
                    }, _}

    assert {"authorization", "Bearer api-graph-key"} in headers
    assert {"model", "s2.1-pro"} in headers
  end

  test "remote failure produces a graph error without exposing provider key or body" do
    assert {:ok, %{"status" => "error"} = result} = AudioFlowUI.Runs.run_text(graph(401), "Salut")
    refute Jason.encode!(result) =~ "fixture-key"
  end
end
