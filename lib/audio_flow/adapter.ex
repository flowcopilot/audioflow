defmodule AudioFlow.Adapter do
  @moduledoc """
  Engine-neutral inference contract. Runs inside a supervised turn task.

  Emit each output with `emit.(value)`. The callback applies back pressure.
  Return `:ok` or `{:error, reason}`. Exceptions become turn errors.
  STT emits transcript strings, vision emits description strings, LLM emits
  speakable text chunks, and TTS emits `AudioFlow.Audio` values. Embedding
  adapters emit vectors for direct inference callers. Keep model weights in
  shared services.
  """
  @callback run(input :: term(), options :: keyword(), emit :: (term() -> :ok)) ::
              :ok | {:error, term()}

  def run({module, options}, input, emit) do
    case module.run(input, options, emit) do
      :ok -> :ok
      {:error, reason} -> throw({:adapter_error, module, reason})
      other -> raise "invalid adapter result: #{inspect(other)}"
    end
  end
end
