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

  An adapter that has required options implements `c:validate_options/1`, so
  that a wrong option fails when the adapter is configured and not in the
  middle of a call. See `AudioFlow.Adapters.Options` for the checks.
  """
  alias AudioFlow.Adapters.Options

  @callback run(input :: term(), options :: keyword(), emit :: (term() -> :ok)) ::
              :ok | {:error, term()}

  @doc "Merges per-run context into adapter options when the adapter supports it."
  @callback with_context(options :: keyword(), context :: map()) :: keyword()

  @doc """
  Checks the options of one `{module, options}` adapter. Returns `:ok` or raises
  `ArgumentError`. The message names the option key and never an option value,
  because options can hold credentials.
  """
  @callback validate_options(options :: keyword()) :: :ok

  @optional_callbacks with_context: 2, validate_options: 1

  @doc """
  Validates an adapter tuple before any call. Raises `ArgumentError` when the
  options are not a keyword list or when `c:validate_options/1` rejects them.
  An adapter without that callback only has its options shape checked. Returns
  the tuple.
  """
  def validate!({module, options} = adapter) when is_atom(module) do
    Code.ensure_loaded!(module)
    Options.keyword!(options)

    if function_exported?(module, :validate_options, 1) do
      :ok = module.validate_options(options)
    end

    adapter
  end

  def validate!(_adapter), do: raise(ArgumentError, "adapter must be a {module, options} tuple")

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
