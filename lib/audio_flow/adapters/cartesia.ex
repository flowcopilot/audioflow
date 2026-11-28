defmodule AudioFlow.Adapters.Cartesia do
  @moduledoc """
  Cartesia streaming HTTP bytes TTS (raw s16le PCM). See
  https://flowcopilot.github.io/audioflow/docs/features/providers/.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Options
  alias AudioFlow.Adapters.Providers.PCMHTTP
  alias AudioFlow.Adapters.Providers.Socket

  @impl true
  def validate_options(options) do
    Options.sample_rate!(options, Options.pcm_sample_rates(), 24_000)
    for key <- [:model, :voice_id, :api_version], do: Options.string!(options, key)
    for key <- [:language, :endpoint], do: Options.optional_string!(options, key)
    Options.api_key!(options)
    PCMHTTP.validate_options!(options)
  end

  @impl true
  def run(text, options, emit) when is_binary(text) do
    :ok = validate_options(options)
    rate = Keyword.get(options, :sample_rate, 24_000)

    body = %{
      model_id: Keyword.fetch!(options, :model),
      transcript: text,
      voice: Keyword.fetch!(options, :voice_id),
      output_format: %{container: "raw", encoding: "pcm_s16le", sample_rate: rate}
    }

    body = if options[:language], do: Map.put(body, :language, options[:language]), else: body

    PCMHTTP.run(
      Keyword.get(options, :endpoint, "https://api.cartesia.ai/tts/bytes"),
      [
        {"authorization", "Bearer " <> Socket.key(options)},
        {"cartesia-version", Keyword.fetch!(options, :api_version)}
      ],
      body,
      rate,
      options,
      emit
    )
  end
end
