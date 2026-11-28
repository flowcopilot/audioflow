defmodule AudioFlow.Adapters.FishAudio do
  @moduledoc """
  Streaming TTS against a self-hosted Fish Speech `/v1/tts` server.

  Emits mono s16le `AudioFlow.Audio` using the rate from the streaming WAV header.
  The model is loaded by the server; `:reference_id` selects a stored voice.
  `:endpoint` defaults to `http://127.0.0.1:8080/v1/tts`. `:api_key` is optional
  (a string or zero-argument function), for servers started with `--api-key`.
  Blank reference IDs are omitted. `:receive_timeout_ms` defaults to `:timeout_ms`
  (30 seconds), and can be set independently for slow or cold servers.
  See
  https://flowcopilot.github.io/audioflow/docs/features/providers/
  for setup and shared HTTP limits.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Options
  alias AudioFlow.Adapters.Providers.PCMHTTP

  @impl true
  def validate_options(options) do
    Options.optional_string!(options, :endpoint)

    # A blank key means no authorization header, for servers without `--api-key`.
    unless is_nil(options[:api_key]) or is_binary(options[:api_key]) or
             is_function(options[:api_key], 0),
           do: raise(ArgumentError, "api_key must be a string or a function")

    unless is_nil(options[:reference_id]) or is_binary(options[:reference_id]),
      do: raise(ArgumentError, "reference_id must be a string")

    PCMHTTP.validate_options!(options)
  end

  @impl true
  def run(text, options, emit) when is_binary(text) do
    :ok = validate_options(options)

    options =
      Keyword.put_new(options, :receive_timeout_ms, Keyword.get(options, :timeout_ms, 30_000))

    body = %{text: text, format: "wav", streaming: true}

    body =
      case options[:reference_id] do
        nil ->
          body

        id ->
          if String.trim(id) == "", do: body, else: Map.put(body, :reference_id, id)
      end

    headers =
      case api_key(options[:api_key]) do
        key when key in [nil, ""] -> []
        key -> [{"authorization", "Bearer " <> key}]
      end

    PCMHTTP.run(
      Keyword.get(options, :endpoint, "http://127.0.0.1:8080/v1/tts"),
      headers,
      body,
      nil,
      options,
      emit,
      :wav
    )
  end

  defp api_key(key) do
    key = if is_function(key, 0), do: key.(), else: key

    unless is_nil(key) or is_binary(key),
      do: raise(ArgumentError, "api_key must resolve to a string")

    key
  end
end
