defmodule AudioFlow.Graph.Nodes.Providers do
  @moduledoc """
  Single-output remote speech stages. Credentials are resolved on the server
  at execution time from fixed provider environment variables, never graph data.
  Mixed-output speech-to-speech adapters deliberately do not appear here.
  """
  @behaviour AudioFlow.Graph.Node
  @providers %{
    "deepgram.stt" => {AudioFlow.STT.ReqLLM, "DEEPGRAM_API_KEY"},
    "mistral.stt" => {AudioFlow.STT.ReqLLM, "MISTRAL_API_KEY"},
    "elevenlabs.tts" => {AudioFlow.Adapters.ElevenLabs, "ELEVENLABS_API_KEY"},
    "cartesia.tts" => {AudioFlow.Adapters.Cartesia, "CARTESIA_API_KEY"},
    "fish_audio.tts" => {AudioFlow.Adapters.FishAudio, "FISH_SPEECH_API_KEY"},
    "fish_audio_api.tts" => {AudioFlow.Adapters.FishAudioAPI, "FISH_AUDIO_API_KEY"}
  }

  @stt_providers %{"deepgram.stt" => :deepgram, "mistral.stt" => :mistral}

  def providers, do: @providers

  @impl true
  def prerequisites("fish_audio.tts", _options) do
    endpoint = Application.get_env(:audio_flow, :speech_provider_endpoints, %{})["fish_audio.tts"]

    if endpoint in [nil, ""],
      do: ["configure speech_provider_endpoints for fish_audio.tts in the server application"],
      else: []
  end

  def prerequisites(type, _options) do
    {_module, env} = Map.fetch!(@providers, type)
    if System.get_env(env) in [nil, ""], do: ["set #{env} in the server environment"], else: []
  end

  @impl true
  def nodes, do: remote_nodes() ++ [fish_node(), fish_api_node()]

  defp remote_nodes do
    for {type, {_adapter, env}} <- Enum.sort(@providers),
        type not in ["fish_audio.tts", "fish_audio_api.tts"] do
      stt? = String.ends_with?(type, ".stt")

      %{
        type: type,
        title: type,
        description:
          "Real remote inference; requires server #{env}. Account model/language availability applies.",
        input: if(stt?, do: :audio, else: :text),
        output: if(stt?, do: :text, else: :audio),
        event: if(stt?, do: :transcript, else: :audio),
        input_mode: if(stt?, do: :join, else: :stream),
        options:
          [
            %{name: :model, type: :string, required: true},
            %{
              name: :language,
              type: :string,
              description: "Provider language code, e.g. en or ro; omit for provider default."
            },
            %{name: :timeout_ms, type: :integer, default: 30_000}
          ] ++
            if(stt?,
              do: [],
              else: [
                %{name: :voice_id, type: :string, required: true},
                %{
                  name: :sample_rate,
                  type: {:enum, [8000, 16_000, 22_050, 24_000, 44_100, 48_000]},
                  default: 24_000
                }
              ]
            ) ++
            if(type == "cartesia.tts",
              do: [
                %{name: :api_version, type: :string, required: true}
              ],
              else: []
            )
      }
    end
  end

  defp fish_node do
    %{
      type: "fish_audio.tts",
      title: "Fish Speech (self-hosted)",
      description:
        "Self-hosted Fish Speech TTS; configure a trusted server endpoint. Optional server API key.",
      input: :text,
      output: :audio,
      event: :audio,
      input_mode: :stream,
      options: [
        %{
          name: :reference_id,
          type: :string,
          description: "Stored voice reference ID; omit for the model default."
        },
        %{name: :timeout_ms, type: :integer, default: 30_000},
        %{
          name: :receive_timeout_ms,
          type: :integer,
          description:
            "Maximum idle wait for audio; defaults to timeout_ms. Increase for slow or cold servers."
        }
      ]
    }
  end

  defp fish_api_node do
    %{
      fish_node()
      | type: "fish_audio_api.tts",
        title: "Fish Audio API",
        description:
          "Hosted Fish Audio TTS; requires server FISH_AUDIO_API_KEY and a hosted voice ID.",
        options:
          [
            %{
              name: :model,
              type: :string,
              required: true,
              description: "Hosted TTS model, e.g. s2.1-pro."
            },
            %{
              name: :reference_id,
              type: :string,
              required: true,
              description: "Hosted voice model ID."
            },
            %{
              name: :sample_rate,
              type: {:enum, [8_000, 16_000, 24_000, 32_000, 44_100]},
              default: 44_100
            },
            %{
              name: :language,
              type: :string,
              description: "Optional text-normalization language, e.g. en or ro."
            },
            %{name: :latency, type: {:enum, ["normal", "balanced", "low"]}, default: "normal"}
          ] ++ Enum.reject(fish_node().options, &(&1.name == :reference_id))
    }
  end

  @impl true
  # STT nodes use ReqLLM with a fixed provider, so graph data cannot select another
  # one. ReqLLM reads the provider key at request time. A trusted endpoint is the
  # API base URL.
  def adapter(type, options) when is_map_key(@stt_providers, type) do
    endpoint = Application.get_env(:audio_flow, :speech_provider_endpoints, %{})[type]
    {timeout, options} = Map.pop(options, :timeout_ms, 30_000)
    {model, options} = Map.pop!(options, :model)

    {AudioFlow.STT.ReqLLM,
     Map.to_list(options) ++
       [model: %{provider: @stt_providers[type], id: model}, receive_timeout: timeout] ++
       if(endpoint, do: [base_url: endpoint], else: [])}
  end

  def adapter(type, options) do
    {module, env} = Map.fetch!(@providers, type)
    endpoint = Application.get_env(:audio_flow, :speech_provider_endpoints, %{})[type]

    if type == "fish_audio.tts" and endpoint in [nil, ""],
      do: raise(ArgumentError, "configure speech_provider_endpoints for fish_audio.tts")

    trusted = if endpoint, do: [endpoint: endpoint], else: []
    {module, Map.to_list(options) ++ trusted ++ [api_key: fn -> System.get_env(env) end]}
  end
end
