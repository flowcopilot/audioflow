defmodule AudioFlow.Adapters.ElevenLabs do
  @moduledoc """
  ElevenLabs streaming HTTP TTS (raw s16le PCM). See
  https://flowcopilot.github.io/audioflow/docs/features/providers/.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Options
  alias AudioFlow.Adapters.Providers.PCMHTTP
  alias AudioFlow.Adapters.Providers.Socket

  @impl true
  def validate_options(options) do
    Options.sample_rate!(options, Options.pcm_sample_rates(), 24_000)
    for key <- [:model, :voice_id], do: Options.string!(options, key)
    for key <- [:language, :endpoint], do: Options.optional_string!(options, key)
    Options.api_key!(options)
    PCMHTTP.validate_options!(options)
  end

  @impl true
  def run(text, options, emit) when is_binary(text) do
    :ok = validate_options(options)
    rate = Keyword.get(options, :sample_rate, 24_000)

    voice = URI.encode(Keyword.fetch!(options, :voice_id), &URI.char_unreserved?/1)

    endpoint =
      Keyword.get(
        options,
        :endpoint,
        "https://api.elevenlabs.io/v1/text-to-speech/#{voice}/stream"
      )

    body = %{text: text, model_id: Keyword.fetch!(options, :model)}

    body =
      if options[:language], do: Map.put(body, :language_code, options[:language]), else: body

    PCMHTTP.run(
      Socket.url(endpoint, %{"output_format" => "pcm_#{rate}"}),
      [{"xi-api-key", Socket.key(options)}],
      body,
      rate,
      options,
      emit
    )
  end
end
