defmodule AudioFlow.Adapters.ElevenLabs do
  @moduledoc "ElevenLabs streaming HTTP TTS (raw s16le PCM). See docs/providers.md."
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Providers.{PCMHTTP, Socket}

  @impl true
  def run(text, options, emit) when is_binary(text) do
    rate = Keyword.get(options, :sample_rate, 24_000)

    unless rate in [8_000, 16_000, 22_050, 24_000, 44_100, 48_000],
      do: raise(ArgumentError, "unsupported PCM sample rate")

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
