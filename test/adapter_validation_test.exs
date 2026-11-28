defmodule AudioFlow.AdapterValidationTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapter
  alias AudioFlow.Adapters.Cartesia
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Adapters.ElevenLabs
  alias AudioFlow.Adapters.FishAudio
  alias AudioFlow.Adapters.FishAudioAPI
  alias AudioFlow.Adapters.GeminiLive
  alias AudioFlow.Adapters.Providers.Socket
  alias AudioFlow.Adapters.ReqLLM
  alias AudioFlow.STT

  @secret "sk-test-secret-value"

  defp message(fun) do
    error = assert_raise ArgumentError, fun
    refute error.message =~ @secret
    error.message
  end

  defp cartesia(extra \\ []),
    do:
      Keyword.merge(
        [model: "m", voice_id: "v", api_version: "2026-03-01", api_key: @secret],
        extra
      )

  defp fish_api(extra \\ []),
    do: Keyword.merge([model: "m", reference_id: "r", api_key: @secret], extra)

  test "an adapter without validate_options gets a shape check only" do
    assert {Demo, [stage: :stt]} = Adapter.validate!({Demo, [stage: :stt]})

    assert "options must be a keyword list" =
             message(fn -> Adapter.validate!({Demo, @secret}) end)

    assert "adapter must be a {module, options} tuple" =
             message(fn -> Adapter.validate!(@secret) end)
  end

  test "valid options pass and the tuple is returned" do
    for adapter <- [
          {Cartesia, cartesia()},
          {ElevenLabs, [model: "m", voice_id: "v", api_key: fn -> @secret end]},
          {FishAudioAPI, fish_api()},
          {FishAudio, []},
          {FishAudio, [api_key: "", endpoint: "http://127.0.0.1:8080/v1/tts"]},
          {GeminiLive, [model: "m", api_key: @secret]},
          {ReqLLM, [model: "openai:gpt-4o-mini"]},
          {STT.ReqLLM, [model: "deepgram:nova-3", api_key: @secret]}
        ] do
      assert ^adapter = Adapter.validate!(adapter)
    end
  end

  test "required options fail at validation and name only the key" do
    for {adapter, options, expected} <- [
          {Cartesia, Keyword.delete(cartesia(), :voice_id), "voice_id is required"},
          {Cartesia, cartesia(sample_rate: 12_345), "sample_rate must be one of"},
          {Cartesia, Keyword.delete(cartesia(), :api_key), "api_key is required"},
          {Cartesia, cartesia(timeout_ms: 0), "timeout_ms must be a positive integer"},
          {ElevenLabs, [model: "m", api_key: @secret], "voice_id is required"},
          {ElevenLabs, [model: " ", voice_id: "v", api_key: @secret], "model must be a nonempty"},
          {FishAudioAPI, Keyword.delete(fish_api(), :reference_id), "reference_id is required"},
          {FishAudioAPI, fish_api(latency: "fast"), "latency must be one of"},
          {FishAudioAPI, fish_api(api_key: 5), "api_key must be a nonempty string or a function"},
          {FishAudio, [api_key: 5], "api_key must be a string or a function"},
          {GeminiLive, [model: "m"], "api_key is required"},
          {ReqLLM, [api_key: @secret], "model is required"},
          {ReqLLM, [model: "m", audio_flow: [max_text_bytes: 0]], "max_text_bytes must be"},
          {ReqLLM, [model: "m", audio_flow: [tool_context: @secret]],
           "tool_context must be a map"},
          {STT.ReqLLM, [model: "m", api_key: 5], "api_key must be a nonempty string"}
        ] do
      assert message(fn -> Adapter.validate!({adapter, options}) end) =~ expected
    end
  end

  test "run raises the same ArgumentError, never a KeyError that quotes the options" do
    emit = fn _ -> flunk("unexpected output") end

    assert message(fn -> Cartesia.run("Hi", Keyword.delete(cartesia(), :voice_id), emit) end) =~
             "voice_id is required"

    assert message(fn -> ElevenLabs.run("Hi", [model: "m", api_key: @secret], emit) end) =~
             "voice_id is required"

    assert message(fn -> FishAudioAPI.run("Hi", Keyword.delete(fish_api(), :model), emit) end) =~
             "model is required"
  end

  test "the API key helper raises for a missing or invalid key and never prints it" do
    assert @secret == Socket.key(api_key: @secret)
    assert @secret == Socket.key(api_key: fn -> @secret end)

    for options <- [[], [api_key: nil], [api_key: ""], [api_key: fn -> nil end], [api_key: 5]] do
      assert message(fn -> Socket.key(options) end) =~ "api_key must be a nonempty string"
    end
  end
end
