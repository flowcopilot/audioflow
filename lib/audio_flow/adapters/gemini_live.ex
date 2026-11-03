defmodule AudioFlow.Adapters.GeminiLive do
  @moduledoc """
  One committed audio turn over Gemini Live v1beta WebSocket.
  Direct callers receive transcript/text deltas and Audio tuples, like OpenAIRealtime.
  Use directly or in Session `:speech_to_speech`; see docs/providers.md.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Providers.Socket

  def run(audio, options, emit) do
    Socket.audio!(audio, 16_000)

    setup = %{
      model: Keyword.fetch!(options, :model),
      generationConfig: %{responseModalities: ["AUDIO"]},
      inputAudioTranscription: %{},
      outputAudioTranscription: %{},
      realtimeInputConfig: %{automaticActivityDetection: %{disabled: true}}
    }

    setup =
      if options[:instructions],
        do: Map.put(setup, :systemInstruction, %{parts: [%{text: options[:instructions]}]}),
        else: setup

    input =
      Enum.map(
        [
          %{realtimeInput: %{activityStart: %{}}},
          %{
            realtimeInput: %{
              audio: %{mimeType: "audio/pcm;rate=16000", data: Base.encode64(audio.data)}
            }
          },
          %{realtimeInput: %{activityEnd: %{}}}
        ],
        &Socket.json/1
      )

    endpoint =
      Keyword.get(
        options,
        :endpoint,
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
      )

    Socket.run(
      Socket.url(endpoint, %{"key" => Socket.key(options)}),
      [],
      [Socket.json(%{setup: setup})],
      false,
      fn
        %{"setupComplete" => _}, false ->
          {:cont, true, input}

        %{"error" => _}, _ ->
          {:error, :remote_error}

        %{"toolCall" => _}, _ ->
          {:error, :unsupported_tool_call}

        %{"goAway" => _}, _ ->
          {:error, :server_go_away}

        %{"serverContent" => %{"interrupted" => true}}, _ ->
          {:error, :interrupted}

        %{"serverContent" => content}, sent ->
          server_content(content, sent, emit)

        _, sent ->
          {:cont, sent, []}
      end,
      options
    )
  end

  defp server_content(content, sent, emit) do
    case content(content, emit) do
      :ok -> if content["turnComplete"], do: :done, else: {:cont, sent, []}
      error -> error
    end
  end

  defp content(content, emit) do
    for {field, kind} <- [{"inputTranscription", :transcript}, {"outputTranscription", :text}],
        %{"text" => text} <- [content[field]],
        is_binary(text),
        do: :ok = emit.({kind, text})

    parts = get_in(content, ["modelTurn", "parts"]) || []

    Enum.reduce_while(parts, :ok, fn
      %{"inlineData" => %{"mimeType" => "audio/pcm;rate=24000", "data" => data}}, :ok ->
        case Socket.audio_event(data, 24_000, emit) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      %{"inlineData" => _}, _ ->
        {:halt, {:error, :unsupported_audio_format}}

      _, :ok ->
        {:cont, :ok}
    end)
  end
end
