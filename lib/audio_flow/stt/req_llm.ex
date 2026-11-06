defmodule AudioFlow.STT.ReqLLM do
  @moduledoc """
  Speech-to-text with an external service, through `ReqLLM.transcribe/3`.

  This adapter follows the common `AudioFlow.STT` interface. `:model` is any
  ReqLLM model input, for example:

    * `"mistral:voxtral-mini-latest"` - Mistral Voxtral
    * `"deepgram:nova-3"` - Deepgram, through `AudioFlow.STT.DeepgramProvider`
    * `"openai:gpt-4o-transcribe"` or `"openai:whisper-1"`
    * `"groq:whisper-large-v3-turbo"`, ElevenLabs Scribe and OpenRouter models
    * `"vllm:mistralai/Voxtral-Mini-3B-2507"` with `:base_url` - a self-hosted
      server with an OpenAI-compatible `/audio/transcriptions` endpoint

  Other options go to ReqLLM unchanged, for example `:provider_options`,
  `:base_url`, `:api_key` and `:receive_timeout`. `:api_key` can also be a
  function of no arguments, called for each request. ReqLLM reads the API key from
  the provider environment variable, for example `MISTRAL_API_KEY`, when
  `:api_key` is not set. `:max_retries` defaults to 0, because the session
  deadline bounds the turn.

  The input PCM is sent as one WAV file. The adapter makes one request for each
  utterance. With `segments: true`, the adapter asks Mistral and Deepgram for
  segment timestamps. OpenAI-compatible providers return segments for Whisper
  models without a request; GPT-4o transcription models return only text, so
  the adapter then emits text. ReqLLM puts word timestamps in the same list as
  segments, so do not request word timestamps. Mistral does not accept segment
  timestamps together with `:language`; the adapter then sends only the
  language, and emits text.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Audio
  alias AudioFlow.STT
  alias AudioFlow.Transcript.Segment

  @impl true
  def run(%Audio{} = audio, options, emit) do
    unless Audio.valid?(audio) and audio.data != <<>>,
      do: raise(ArgumentError, "expected nonempty mono s16le PCM")

    {common, options} = STT.split_options!(options)
    {:ok, model} = ReqLLM.model(model_input(common.model))

    options =
      options
      |> Keyword.put_new(:max_retries, 0)
      |> resolve_key()
      |> put_language(common.language)
      |> put_segments(model.provider, common.segments, common.language)

    case ReqLLM.transcribe(model, {:binary, AudioFlow.Wav.encode(audio), "audio/wav"}, options) do
      {:ok, result} ->
        STT.emit(segments(result.segments), result.text, common.segments, emit)

      {:error, %{status: status}} when is_integer(status) ->
        {:error, {:http_status, status}}

      {:error, error} when is_exception(error) ->
        {:error, {:transcription, Exception.message(error)}}

      {:error, reason} ->
        {:error, {:transcription, reason}}
    end
  end

  def run(_input, _options, _emit), do: raise(ArgumentError, "expected AudioFlow.Audio input")

  # A key function runs at request time, so session options need not hold the key.
  defp resolve_key(options) do
    case Keyword.get(options, :api_key) do
      key when is_function(key, 0) -> Keyword.put(options, :api_key, key.())
      _ -> options
    end
  end

  # Deepgram models are not in the ReqLLM catalog; an inline spec avoids a warning.
  defp model_input("deepgram:" <> id), do: %{provider: :deepgram, id: id}
  defp model_input(model), do: model

  defp put_language(options, nil), do: options
  defp put_language(options, language), do: Keyword.put(options, :language, language)

  defp put_segments(options, :mistral, true, nil),
    do: put_provider_option(options, :timestamp_granularities, "segment")

  defp put_segments(options, :deepgram, true, _language),
    do: put_provider_option(options, :utterances, true)

  defp put_segments(options, _provider, _segments?, _language), do: options

  defp put_provider_option(options, key, value) do
    provider_options = options |> Keyword.get(:provider_options, []) |> Enum.into([])
    Keyword.put(options, :provider_options, Keyword.put_new(provider_options, key, value))
  end

  defp segments(segments) do
    for segment <- segments do
      %Segment{
        text: String.trim(segment.text),
        start_ms: ms(segment.start_second),
        end_ms: ms(segment.end_second)
      }
    end
  end

  defp ms(seconds) when is_number(seconds) and seconds >= 0, do: round(seconds * 1000)
  defp ms(_), do: nil
end
