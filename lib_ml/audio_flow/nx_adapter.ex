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

  @doc "Convert floating point speech output to bounded mono s16le PCM chunks."
  def speech_audio(%{audio: samples, sampling_rate: rate}) do
    # Clamp before conversion so model overshoot cannot wrap a signed sample.
    pcm =
      samples
      |> Nx.flatten()
      |> Nx.clip(-1.0, 32767 / 32768)
      |> Nx.multiply(32768)
      |> Nx.round()
      |> Nx.as_type(:s16)
      |> Nx.backend_transfer(Nx.BinaryBackend)
      |> Nx.to_binary()

    # Nx uses native byte order. PCM transport has an explicit little-endian order.
    pcm =
      if System.endianness() == :little,
        do: pcm,
        else:
          for(<<sample::native-signed-16 <- pcm>>, into: <<>>, do: <<sample::little-signed-16>>)

    for chunk <- chunks(pcm, max(2, div(rate, 50) * 2)),
        do: %AudioFlow.Audio{data: chunk, sample_rate: rate}
  end

  defp chunks(<<>>, _size), do: []
  defp chunks(data, size) when byte_size(data) <= size, do: [data]

  defp chunks(data, size) do
    [binary_part(data, 0, size) | chunks(binary_part(data, size, byte_size(data) - size), size)]
  end

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
