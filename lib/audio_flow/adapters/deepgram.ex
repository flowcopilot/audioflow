defmodule AudioFlow.Adapters.Deepgram do
  @moduledoc "Deepgram Listen v1 WebSocket STT for a committed PCM utterance. See docs/providers.md."
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Providers.Socket

  @impl true
  def run(audio, options, emit) do
    Socket.audio!(audio)
    endpoint = Keyword.get(options, :endpoint, "wss://api.deepgram.com/v1/listen")

    params = %{
      "model" => Keyword.fetch!(options, :model),
      "encoding" => "linear16",
      "sample_rate" => audio.sample_rate,
      "channels" => 1,
      "interim_results" => false
    }

    params =
      if options[:language], do: Map.put(params, "language", options[:language]), else: params

    chunks = for <<chunk::binary-size(16_000) <- audio.data>>, do: {:binary, chunk}
    remainder = rem(byte_size(audio.data), 16_000)

    chunks =
      if remainder > 0,
        do:
          chunks ++
            [{:binary, binary_part(audio.data, byte_size(audio.data) - remainder, remainder)}],
        else: chunks

    Socket.run(
      Socket.url(endpoint, params),
      [{"authorization", "Token " <> Socket.key(options)}],
      chunks ++ [Socket.json(%{type: "CloseStream"})],
      false,
      fn
        %{
          "type" => "Results",
          "is_final" => true,
          "channel" => %{"alternatives" => [%{"transcript" => text} | _]}
        },
        seen
        when is_binary(text) ->
          final_transcript(text, seen, emit)

        %{"type" => "Metadata"}, _ ->
          :done

        %{"type" => "Error"}, _ ->
          {:error, :remote_error}

        %{"type" => type}, seen when type in ["Results", "SpeechStarted", "UtteranceEnd"] ->
          {:cont, seen, []}

        _, _ ->
          {:error, :invalid_event}
      end,
      options
    )
  end

  defp final_transcript(text, seen, emit) do
    if text != "", do: :ok = emit.(if(seen, do: " " <> text, else: text))
    {:cont, seen or text != "", []}
  end
end
