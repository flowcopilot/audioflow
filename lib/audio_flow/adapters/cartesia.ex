defmodule AudioFlow.Adapters.Cartesia do
  @moduledoc "Cartesia streaming HTTP bytes TTS (raw s16le PCM). See docs/providers.md."
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Providers.{PCMHTTP, Socket}

  @impl true
  def run(text, options, emit) when is_binary(text) do
    rate = Keyword.get(options, :sample_rate, 24_000)

    unless rate in [8_000, 16_000, 22_050, 24_000, 44_100, 48_000],
      do: raise(ArgumentError, "unsupported PCM sample rate")

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
