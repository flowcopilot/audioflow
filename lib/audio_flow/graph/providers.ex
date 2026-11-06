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
    "cartesia.tts" => {AudioFlow.Adapters.Cartesia, "CARTESIA_API_KEY"}
  }

  @stt_providers %{"deepgram.stt" => :deepgram, "mistral.stt" => :mistral}

  def providers, do: @providers

  @impl true
  def prerequisites(type, _options) do
    {_module, env} = Map.fetch!(@providers, type)
    if System.get_env(env) in [nil, ""], do: ["set #{env} in the server environment"], else: []
  end

  @impl true
  def nodes do
    for {type, {_adapter, env}} <- Enum.sort(@providers) do
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
    trusted = if endpoint, do: [endpoint: endpoint], else: []
    {module, Map.to_list(options) ++ trusted ++ [api_key: fn -> System.get_env(env) end]}
  end
end
