defmodule AudioFlow.Adapters.FishAudioAPI do
  @moduledoc """
  Fish Audio hosted HTTP TTS, emitting mono s16le PCM during the response.

  Requires `:model`, `:reference_id` (a hosted voice ID), and `:api_key` (a string
  or zero-argument function). `:sample_rate` defaults to 44,100 Hz; supported
  rates are 8,000, 16,000, 24,000, 32,000 and 44,100 Hz. Optional `:language`
  controls text normalization, and `:latency` is `"normal"`, `"balanced"` or
  `"low"`. The endpoint defaults to `https://api.fish.audio/v1/tts`.

  `:receive_timeout_ms` defaults to `:timeout_ms` (30 seconds).
  For a self-hosted Fish Speech server, use `AudioFlow.Adapters.FishAudio`.
  See
  https://flowcopilot.github.io/audioflow/docs/features/providers/
  for configuration and shared HTTP bounds.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Options
  alias AudioFlow.Adapters.Providers.PCMHTTP
  alias AudioFlow.Adapters.Providers.Socket

  @rates [8_000, 16_000, 24_000, 32_000, 44_100]
  @latencies ["normal", "balanced", "low"]

  @impl true
  def validate_options(options) do
    Options.sample_rate!(options, @rates, 44_100)
    for key <- [:model, :reference_id], do: Options.string!(options, key)
    for key <- [:language, :endpoint], do: Options.optional_string!(options, key)
    Options.one_of!(options, :latency, @latencies, "normal")
    Options.api_key!(options)
    PCMHTTP.validate_options!(options)
  end

  @impl true
  def run(text, options, emit) when is_binary(text) do
    :ok = validate_options(options)
    rate = Keyword.get(options, :sample_rate, 44_100)
    key = Socket.key(options)
    model = Keyword.fetch!(options, :model)
    reference = Keyword.fetch!(options, :reference_id)
    latency = Keyword.get(options, :latency, "normal")

    body = %{
      text: text,
      reference_id: reference,
      format: "pcm",
      sample_rate: rate,
      latency: latency
    }

    body = if options[:language], do: Map.put(body, :language, options[:language]), else: body

    options =
      Keyword.put_new(options, :receive_timeout_ms, Keyword.get(options, :timeout_ms, 30_000))

    PCMHTTP.run(
      Keyword.get(options, :endpoint, "https://api.fish.audio/v1/tts"),
      [{"authorization", "Bearer " <> key}, {"model", model}],
      body,
      rate,
      options,
      emit
    )
  end
end
