defmodule AudioFlow.Adapters.Deepgram do
  @moduledoc """
  Deepgram Listen v1 WebSocket STT for a committed PCM utterance. See docs/providers.md.

  Set `interim_results: true` to emit `{:partial, text}` for interim results.
  Set `segments: true` to emit timed `AudioFlow.Transcript.Segment` values in
  place of strings.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Providers.Socket
  alias AudioFlow.Transcript.Segment

  @impl true
  def run(audio, options, emit) do
    Socket.audio!(audio)
    endpoint = Keyword.get(options, :endpoint, "wss://api.deepgram.com/v1/listen")

    params = %{
      "model" => Keyword.fetch!(options, :model),
      "encoding" => "linear16",
      "sample_rate" => audio.sample_rate,
      "channels" => 1,
      "interim_results" => Keyword.get(options, :interim_results, false) == true
    }

    segments? = Keyword.get(options, :segments, false) == true

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
          "channel" => %{"alternatives" => [%{"transcript" => text} = alternative | _]}
        } = event,
        seen
        when is_binary(text) ->
          if segments?,
            do: final_segment(event, alternative, seen, emit),
            else: final_transcript(text, seen, emit)

        %{
          "type" => "Results",
          "is_final" => false,
          "channel" => %{"alternatives" => [%{"transcript" => text} | _]}
        },
        seen
        when is_binary(text) ->
          if text != "", do: :ok = emit.({:partial, text})
          {:cont, seen, []}

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

  defp final_segment(event, alternative, seen, emit) do
    with {:ok, start_ms, end_ms} <- result_time(event),
         {:ok, words} <- words(Map.get(alternative, "words", [])) do
      text = alternative["transcript"]

      if text != "",
        do: :ok = emit.(%Segment{text: text, start_ms: start_ms, end_ms: end_ms, words: words})

      {:cont, seen or text != "", []}
    end
  end

  defp result_time(%{"start" => start, "duration" => duration})
       when is_number(start) and is_number(duration) and start >= 0 and duration >= 0,
       do: {:ok, ms(start), ms(start + duration)}

  defp result_time(_), do: {:error, :invalid_event}

  defp words(words) when is_list(words) do
    Enum.reduce_while(words, {:ok, []}, fn
      %{"word" => word, "start" => start, "end" => stop} = item, {:ok, acc}
      when is_binary(word) and is_number(start) and is_number(stop) and 0 <= start and
             start <= stop ->
        word = %{
          word: if(is_binary(item["punctuated_word"]), do: item["punctuated_word"], else: word),
          start_ms: ms(start),
          end_ms: ms(stop)
        }

        word =
          if is_number(item["confidence"]),
            do: Map.put(word, :confidence, item["confidence"]),
            else: word

        {:cont, {:ok, [word | acc]}}

      _, _ ->
        {:halt, {:error, :invalid_event}}
    end)
    |> case do
      {:ok, words} -> {:ok, Enum.reverse(words)}
      error -> error
    end
  end

  defp words(_), do: {:error, :invalid_event}

  defp ms(seconds), do: round(seconds * 1000)

  defp final_transcript(text, seen, emit) do
    if text != "", do: :ok = emit.(if(seen, do: " " <> text, else: text))
    {:cont, seen or text != "", []}
  end
end
