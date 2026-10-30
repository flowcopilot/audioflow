defmodule AudioFlow.NxAdapter do
  @moduledoc """
  Calls an existing named Nx.Serving; never loads weights per session.

  Options: `:serving`, `:input` (input mapping function), `:output` (maps
  a serving result to an enumerable of adapter outputs). The serving stream
  is consumed in the process which calls `batched_run/2`, as Nx requires.
  This also supports application-owned ONNX/Transmuter servings.
  """
  @behaviour AudioFlow.Adapter

  @impl true
  def run(input, options, emit) do
    input = Keyword.get(options, :input, &Function.identity/1).(input)
    result = Nx.Serving.batched_run(Keyword.fetch!(options, :serving), input)
    outputs = Keyword.fetch!(options, :output).(result)
    Enum.each(outputs, emit)
    :ok
  end

  @doc "Convert mono PCM to a Whisper input tensor, without hidden resampling."
  def whisper_input(%AudioFlow.Audio{sample_rate: 16_000, data: data}) do
    samples = for <<sample::little-signed-16 <- data>>, do: sample / 32_768
    Nx.tensor(samples, type: :f32)
  end

  def whisper_input(_), do: raise(ArgumentError, "Whisper requires 16000 Hz mono PCM")

  def transcript(%{chunks: chunks}), do: Enum.map(chunks, & &1.text)

  @doc "Group a Bumblebee generation stream into speakable sentences."
  def sentences(stream) do
    Stream.transform(
      stream,
      fn -> "" end,
      fn chunk, pending ->
        parts = Regex.split(~r/(?<=[.!?])\s+/, pending <> chunk)
        {Enum.drop(parts, -1), List.last(parts)}
      end,
      fn pending ->
        {if(String.trim(pending) == "", do: [], else: [pending]), ""}
      end,
      fn _ -> :ok end
    )
  end
end
