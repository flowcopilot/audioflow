defmodule AudioFlow.Adapters.ReqLLMTranscription do
  @moduledoc """
  STT through `ReqLLM.transcribe/3`, for any ReqLLM transcription provider.

  This covers Mistral Voxtral, OpenAI Whisper and GPT-4o transcription, Groq
  Whisper, ElevenLabs Scribe, OpenRouter, and self-hosted OpenAI-compatible
  servers such as vLLM with Voxtral or Whisper:

      {AudioFlow.Adapters.ReqLLMTranscription, model: "mistral:voxtral-mini-latest"}
      {AudioFlow.Adapters.ReqLLMTranscription, model: "groq:whisper-large-v3-turbo"}
      {AudioFlow.Adapters.ReqLLMTranscription,
       model: "vllm:mistralai/Voxtral-Mini-3B-2507", base_url: "http://localhost:8000/v1"}

  Pass `:model` as any ReqLLM model input. The other options go to ReqLLM
  unchanged, for example `:language`, `:provider_options`, `:base_url`,
  `:api_key` and `:receive_timeout`. `:max_retries` defaults to 0, because the
  session deadline bounds the turn. The input PCM is sent as a WAV file. The
  adapter makes one request for each turn and emits after the response.

  By default the adapter emits the transcript text. Set `segments: true` to emit
  timed `AudioFlow.Transcript.Segment` values. Request segment timestamps from
  the provider: for Mistral, set `provider_options: [timestamp_granularities:
  "segment"]`. ReqLLM puts word timestamps in the same list as segments, so do
  not request word timestamps with `segments: true`. When the response has no
  segments, the adapter emits the text.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Audio
  alias AudioFlow.Transcript.Segment

  @impl true
  def run(%Audio{} = audio, options, emit) do
    unless Audio.valid?(audio) and audio.data != <<>>,
      do: raise(ArgumentError, "expected nonempty mono s16le PCM")

    {model, options} = Keyword.pop!(options, :model)
    {segments?, options} = Keyword.pop(options, :segments, false)
    options = Keyword.put_new(options, :max_retries, 0)
    wav = AudioFlow.Wav.encode(audio)

    case ReqLLM.transcribe(model, {:binary, wav, "audio/wav"}, options) do
      {:ok, result} ->
        outputs(result, segments? == true) |> Enum.each(&(:ok = emit.(&1)))

      {:error, %{status: status}} when is_integer(status) ->
        {:error, {:http_status, status}}

      {:error, error} when is_exception(error) ->
        {:error, {:transcription, Exception.message(error)}}

      {:error, reason} ->
        {:error, {:transcription, reason}}
    end
  end

  def run(_input, _options, _emit), do: raise(ArgumentError, "expected AudioFlow.Audio input")

  defp outputs(%{segments: [_ | _] = segments}, true) do
    for segment <- segments, text = String.trim(segment.text), text != "" do
      %Segment{text: text, start_ms: ms(segment.start_second), end_ms: ms(segment.end_second)}
    end
  end

  defp outputs(%{text: text}, _segments?) when is_binary(text) do
    if String.trim(text) == "", do: [], else: [text]
  end

  defp ms(seconds) when is_number(seconds) and seconds >= 0, do: round(seconds * 1000)
  defp ms(_), do: nil
end
