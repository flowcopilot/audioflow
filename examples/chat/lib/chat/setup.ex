defmodule Chat.Setup do
  @moduledoc "Validated per-tab settings. Credentials are resolved only on the server."
  alias AudioFlow.Adapters

  @modes [
    {"demo", "Synthetic demo"},
    {"local", "Local Apple MLX"},
    {"remote", "Deepgram → Chat HTTP → TTS"},
    {"openai", "OpenAI speech-to-speech"},
    {"gemini", "Gemini speech-to-speech"}
  ]
  @languages ~w(en es fr de ro)
  @voices ~w(marin cedar)
  @tts_providers ~w(elevenlabs cartesia)

  def modes, do: @modes
  def languages, do: @languages
  def voices, do: @voices
  def tts_providers, do: @tts_providers

  def defaults,
    do: %{
      "mode" => if(Chat.Engine.native?(), do: "local", else: "demo"),
      "language" => "en",
      "voice" => "marin",
      "tts" => "elevenlabs"
    }

  def requirements("remote"), do: ["DEEPGRAM_API_KEY", "CHAT_HTTP_ENDPOINT", "CHAT_HTTP_MODEL"]
  def requirements("openai"), do: ["OPENAI_API_KEY", "OPENAI_REALTIME_MODEL"]
  def requirements("gemini"), do: ["GEMINI_API_KEY", "GEMINI_LIVE_MODEL"]
  def requirements(_), do: []
  def rate(%{"mode" => "openai"}), do: 24_000
  def rate(_), do: 16_000
  def speech?(settings), do: settings["mode"] in ["openai", "gemini"]

  def options(s, env \\ &System.get_env/1) do
    mode = s["mode"]
    missing = Enum.filter(required(s), &(env.(&1) in [nil, ""]))

    cond do
      not Enum.any?(@modes, &(elem(&1, 0) == mode)) ->
        {:error, "Unknown mode"}

      not supported?(s) ->
        {:error, "Unsupported language, voice or TTS"}

      mode == "local" and not Chat.Engine.native?() ->
        {:error, "Restart with CHAT_PROFILE=native on Apple Silicon"}

      missing != [] ->
        {:error, "Missing server environment: " <> Enum.join(missing, ", ")}

      true ->
        {:ok,
         build(s, env) ++ [timeout_ms: 120_000, max_events: 4096, max_input_bytes: 1_440_000]}
    end
  end

  defp required(%{"mode" => "remote", "tts" => "cartesia"}),
    do: requirements("remote") ++ ["CARTESIA_API_KEY", "CARTESIA_VOICE_ID"]

  defp required(%{"mode" => "remote"}),
    do: requirements("remote") ++ ["ELEVENLABS_API_KEY", "ELEVENLABS_VOICE_ID"]

  defp required(s), do: requirements(s["mode"])

  defp supported?(s) do
    s["language"] in @languages and s["voice"] in @voices and
      s["tts"] in @tts_providers
  end

  defp key(env, name), do: fn -> env.(name) end
  defp build(%{"mode" => "demo"}, _), do: Adapters.Demo.options() ++ [history: true]
  defp build(%{"mode" => "local"}, _), do: Chat.Stage.session_options()

  defp build(%{"mode" => "remote"} = s, env) do
    tts =
      if s["tts"] == "cartesia",
        do:
          {Adapters.Cartesia,
           [
             model: env.("CARTESIA_MODEL") || "sonic-3.6",
             voice_id: env.("CARTESIA_VOICE_ID"),
             api_version: "2026-08-14",
             api_key: key(env, "CARTESIA_API_KEY"),
             language: s["language"]
           ]},
        else:
          {Adapters.ElevenLabs,
           [
             model: env.("ELEVENLABS_MODEL") || "eleven_multilingual_v2",
             voice_id: env.("ELEVENLABS_VOICE_ID"),
             api_key: key(env, "ELEVENLABS_API_KEY"),
             language: s["language"]
           ]}

    [
      stt:
        {AudioFlow.STT.ReqLLM,
         [
           model: "deepgram:" <> (env.("DEEPGRAM_MODEL") || "nova-3"),
           api_key: key(env, "DEEPGRAM_API_KEY"),
           language: s["language"]
         ]},
      llm:
        {Adapters.ReqLLM,
         [
           base_url: String.replace_suffix(env.("CHAT_HTTP_ENDPOINT"), "/chat/completions", ""),
           model: %{provider: :openai, id: env.("CHAT_HTTP_MODEL")},
           system_prompt: AudioFlow.Prompt.default_system(),
           max_tokens: 128,
           api_key: env.("CHAT_HTTP_API_KEY") || "local"
         ]},
      tts: tts,
      history: true
    ]
  end

  defp build(%{"mode" => "openai"} = s, env),
    do: [
      speech_to_speech:
        {Adapters.OpenAIRealtime,
         [
           model: env.("OPENAI_REALTIME_MODEL"),
           api_key: key(env, "OPENAI_API_KEY"),
           voice: s["voice"]
         ]}
    ]

  defp build(%{"mode" => "gemini"}, env),
    do: [
      speech_to_speech:
        {Adapters.GeminiLive,
         [model: env.("GEMINI_LIVE_MODEL"), api_key: key(env, "GEMINI_API_KEY")]}
    ]
end
