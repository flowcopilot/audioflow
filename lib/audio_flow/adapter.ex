defmodule AudioFlow.Adapter do
  @moduledoc """
  Engine-neutral inference contract. Runs inside a supervised turn task.

  Emit each output with `emit.(value)`. The callback applies back pressure.
  Return `:ok` or `{:error, reason}`. Exceptions become turn errors.
  STT emits transcript strings, vision emits description strings, LLM emits
  speakable text chunks, and TTS emits `AudioFlow.Audio` values. Embedding
  adapters emit vectors for direct inference callers. A Session `:speech_to_speech`
  adapter emits tagged `{:transcript, text}`, `{:text, text}`, `{:audio, audio}`
  values through the same arity-one callback. It is a separate mixed-output
  contract and cannot occupy a single-output stage slot. Keep model weights in
  shared services.
  """
  @callback run(input :: term(), options :: keyword(), emit :: (term() -> :ok)) ::
              :ok | {:error, term()}

  @doc "Merges per-run context into adapter options when the adapter supports it."
  @callback with_context(options :: keyword(), context :: map()) :: keyword()
  @optional_callbacks with_context: 2

  def with_context({module, options}, context) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :with_context, 2),
      do: {module, module.with_context(options, context)},
      else: {module, options}
  end

  def run({module, options}, input, emit) do
    case module.run(input, options, emit) do
      :ok -> :ok
      {:error, reason} -> throw({:adapter_error, module, reason})
      other -> raise "invalid adapter result: #{inspect(other)}"
    end
  end
end
