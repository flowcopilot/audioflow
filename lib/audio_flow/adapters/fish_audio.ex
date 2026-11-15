defmodule AudioFlow.Adapters.FishAudio do
  @moduledoc """
  Streaming TTS against a self-hosted Fish Speech `/v1/tts` server.

  Emits mono s16le `AudioFlow.Audio` using the rate from the streaming WAV header.
  The model is loaded by the server; `:reference_id` selects a stored voice.
  `:endpoint` defaults to `http://127.0.0.1:8080/v1/tts`. `:api_key` is optional
  (a string or zero-argument function), for servers started with `--api-key`.
  Blank reference IDs are omitted. `:receive_timeout_ms` defaults to `:timeout_ms`
  (30 seconds), and can be set independently for slow or cold servers.
  See `docs/providers.md` for setup and shared HTTP limits.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Providers.PCMHTTP
  alias AudioFlow.Adapters.Providers.Socket

  @impl true
  def run(text, options, emit) when is_binary(text) do
    options =
      Keyword.put_new(options, :receive_timeout_ms, Keyword.get(options, :timeout_ms, 30_000))

    body = %{text: text, format: "wav", streaming: true}

    body =
      case options[:reference_id] do
        nil ->
          body

        id when is_binary(id) ->
          if String.trim(id) == "", do: body, else: Map.put(body, :reference_id, id)
      end

    headers =
      if options[:api_key] do
        case Socket.key(options) do
          key when key in [nil, ""] -> []
          key when is_binary(key) -> [{"authorization", "Bearer " <> key}]
        end
      else
        []
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
end
