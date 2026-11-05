defmodule AudioFlow.SmartTurn do
  @moduledoc """
  Smart Turn v3.1 CPU ONNX inference through a persistent Python worker.
  Start with `start_link(executable: python_path, args: [script_path, model_path])`.
  No downloads occur at runtime. Pass `{AudioFlow.SmartTurn, worker: pid}` as
  VoiceInput's `:turn_detector`. Inference receives only the last eight seconds
  at 16 kHz and returns the model's completion probability. See the pinned
  model and dependency installation instructions in `docs/input-processing.md`.
  """
  alias AudioFlow.Audio
  alias AudioFlow.PacketWorker
  def start_link(options), do: PacketWorker.start_link(options)
  def init(options), do: Keyword.fetch!(options, :worker)

  def predict(%Audio{sample_rate: 16_000, data: pcm}, worker) do
    pcm =
      if byte_size(pcm) > 256_000,
        do: binary_part(pcm, byte_size(pcm) - 256_000, 256_000),
        else: pcm

    with {:ok, result} <- PacketWorker.request(worker, pcm, 500),
         {probability, ""} <- Float.parse(result),
         true <- probability >= 0 and probability <= 1 do
      probability
    else
      _ -> raise "Smart Turn worker unavailable or returned an invalid probability"
    end
  end
end
