defmodule AudioFlow.STT.DeepgramProvider do
  @moduledoc """
  A ReqLLM provider for Deepgram pre-recorded transcription (`POST /v1/listen`).

  ReqLLM has no Deepgram provider, so AudioFlow registers this one when it
  starts. Use it through `AudioFlow.STT.ReqLLM` with a model such as
  `"deepgram:nova-3"`. The key comes from `DEEPGRAM_API_KEY` or `:api_key`.

  `:language` becomes the `language` query parameter. `:provider_options` become
  other query parameters, for example `smart_format: true` or
  `utterances: true`. With `utterances: true`, Deepgram utterances become
  ReqLLM segments with start and end times.
  """
  use ReqLLM.Provider,
    id: :deepgram,
    default_base_url: "https://api.deepgram.com",
    default_env_key: "DEEPGRAM_API_KEY"

  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Provider.Defaults
  alias ReqLLM.Step
  alias ReqLLM.Transcription.Result

  @impl ReqLLM.Provider
  def prepare_request(:transcription, model_spec, audio_data, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec) do
      timeout = Keyword.get(opts, :receive_timeout, 120_000)
      http_options = Keyword.get(opts, :req_http_options, [])

      params =
        [model: model.id, language: Keyword.get(opts, :language)] ++
          Enum.into(Keyword.get(opts, :provider_options, []), [])

      request =
        Req.new(
          [
            url: "/v1/listen",
            method: :post,
            base_url: Keyword.get(opts, :base_url, default_base_url()),
            params: for({key, value} <- params, value != nil, do: {key, to_string(value)}),
            headers: [
              {"authorization", "Token " <> ReqLLM.Keys.get!(model, opts)},
              {"content-type", Keyword.get(opts, :media_type, "audio/wav")}
            ],
            body: audio_data,
            receive_timeout: timeout
          ] ++ Defaults.merge_finch_options(http_options, pool_timeout: timeout)
        )
        |> Step.Retry.attach(opts)
        |> Step.Error.attach()
        |> Req.Request.append_response_steps(deepgram_result: &result/1)

      {:ok, request}
    end
  end

  def prepare_request(operation, _model_spec, _input, _opts) do
    {:error,
     Parameter.exception(
       parameter: "operation: #{inspect(operation)} is not supported by Deepgram"
     )}
  end

  @doc false
  def result({request, %Req.Response{status: status, body: body} = response})
      when status in 200..299 and is_map(body) do
    channel = get_in(body, ["results", "channels", Access.at(0)]) || %{}
    alternative = get_in(channel, ["alternatives", Access.at(0)]) || %{}
    utterances = get_in(body, ["results", "utterances"]) || []

    segments =
      for %{"transcript" => text, "start" => start, "end" => stop} <- utterances,
          do: %{text: text, start_second: start, end_second: stop}

    result = %Result{
      text: alternative["transcript"] || "",
      segments: segments,
      language: channel["detected_language"],
      duration_in_seconds: get_in(body, ["metadata", "duration"])
    }

    {request, %{response | body: result}}
  end

  def result(pair), do: pair
end
