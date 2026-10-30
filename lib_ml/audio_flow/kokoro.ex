defmodule AudioFlow.Kokoro do
  @moduledoc """
  Shared Kokoro v1 ONNX synthesis through Transmuter and Nx.Serving.

  `serving/1` loads the model, tokenizer vocabulary, and selected voices once.
  It accepts a text string, `%{text: text, voice: voice, speed: speed}`, or
  `%{phonemes: phonemes, voice: voice, speed: speed}`. Direct phoneme input
  does not require espeak-ng. Only configured voices can be selected.

  Results are a stream of `%{audio: tensor, sampling_rate: 24000}` values.
  Consume the stream in the calling process. Use `audio/1` as the output mapper
  for `AudioFlow.NxAdapter`. Each section runs as its own batch of size one.
  Model inference produces a full section waveform before PCM is emitted.
  """
  @repository "onnx-community/Kokoro-82M-v1.0-ONNX"
  @revision "1939ad2a8e416c0acfeecc08a694d14ef25f2231"
  @phase_node "/decoder/decoder/generator/Greater"

  def serving(options \\ []) do
    source = Keyword.get(options, :source, {:hf, @repository})
    hub_options = Keyword.merge([revision: @revision], Keyword.get(options, :load_options, []))
    voices = Keyword.get(options, :voices, ["af_heart"])

    unless is_list(voices) and voices != [] and Enum.all?(voices, &valid_voice?/1),
      do: raise(ArgumentError, "voices must be a non-empty list of voice names")

    default_voice = Keyword.get(options, :default_voice, hd(voices))
    unless default_voice in voices, do: raise(ArgumentError, "default voice must be loaded")

    vocabulary = Transmuter.Hub.json(source, "tokenizer.json", hub_options)["model"]["vocab"]

    unless is_map(vocabulary) and vocabulary["$"] == 0,
      do: raise(ArgumentError, "invalid Kokoro vocabulary")

    styles =
      Map.new(voices, fn voice ->
        path = Transmuter.Hub.fetch!(source, "voices/#{voice}.bin", hub_options)
        data = File.read!(path)

        unless byte_size(data) >= 510 * 256 * 4 and rem(byte_size(data), 256 * 4) == 0,
          do: raise(ArgumentError, "invalid voice style file: #{voice}")

        # Voice files contain little-endian float32 values.
        samples = for <<value::little-float-32 <- data>>, do: value
        {voice, samples |> Nx.tensor(type: :f32) |> Nx.reshape({:auto, 256})}
      end)

    model_path = Transmuter.Hub.fetch!(source, "onnx/model.onnx", hub_options)

    model =
      Transmuter.load!(model_path, Keyword.take(hub_options, [:backend, :compute_type]))
      |> correct_phase()

    phonemizer = Keyword.get(options, :phonemizer, {AudioFlow.Phonemizers.ESpeak, []})
    defn_options = Keyword.get(options, :defn_options, compiler: EXLA)
    cache_size = Keyword.get(options, :cache_size, 64)

    unless is_integer(cache_size) and cache_size > 0,
      do: raise(ArgumentError, "cache_size must be positive")

    Nx.Serving.new(
      fn compiler_options ->
        template = %{
          "input_ids" => Nx.template({1, 4}, :s64),
          "style" => Nx.template({1, 256}, :f32),
          "speed" => Nx.template({1}, :f32)
        }

        run =
          Transmuter.compile(
            model,
            template,
            [cache_size: cache_size] ++ Keyword.delete(compiler_options, :batch_keys)
          )

        fn batch ->
          if batch.size != 1, do: raise(ArgumentError, "Kokoro requires batch_size: 1")
          inputs = Nx.Defn.jit_apply(& &1, [batch], compiler: Nx.Defn.Evaluator)
          output = run.(inputs)
          %{audio: Nx.reshape(output["waveform"], {1, :auto})}
        end
      end,
      defn_options
    )
    |> Nx.Serving.batch_size(1)
    |> Nx.Serving.streaming()
    |> Nx.Serving.client_preprocessing(fn input ->
      {phonemes, voice, speed} = prepare(input, default_voice, styles, phonemizer)

      batches =
        encode(phonemes, vocabulary)
        |> Enum.map(fn ids ->
          count = length(ids) - 2

          style =
            Nx.slice_along_axis(styles[voice], count - 1, 1, axis: 0) |> Nx.squeeze(axes: [0])

          Nx.Batch.stack([
            %{
              "input_ids" => Nx.tensor(ids, type: :s64),
              "style" => style,
              "speed" => Nx.tensor(speed, type: :f32)
            }
          ])
        end)

      {batches, nil}
    end)
    |> Nx.Serving.client_postprocessing(fn stream, _ ->
      Stream.map(stream, fn {:batch, %{audio: audio}, _metadata} ->
        %{audio: Nx.squeeze(audio, axes: [0]), sampling_rate: 24_000}
      end)
    end)
  end

  @doc "Convert a Kokoro result stream into PCM chunks for the session."
  def audio(stream), do: Stream.flat_map(stream, &AudioFlow.NxAdapter.speech_audio/1)

  @doc "Encode phonemes into sections of up to 510 symbols, with boundary tokens."
  def encode(phonemes, vocabulary) when is_binary(phonemes) and is_map(vocabulary) do
    if byte_size(phonemes) > 32_768 or not String.valid?(phonemes),
      do: raise(ArgumentError, "invalid or oversized phoneme input")

    symbols = phonemes |> String.trim() |> String.codepoints()
    if symbols == [], do: raise(ArgumentError, "phoneme input is empty")
    # Every symbol is checked before inference. Unknown symbols are never dropped.
    ids =
      Enum.map(symbols, fn symbol ->
        Map.get(vocabulary, symbol) ||
          raise(ArgumentError, "unsupported phoneme: #{inspect(symbol)}")
      end)

    split(ids, vocabulary[" "]) |> Enum.map(&([0] ++ &1 ++ [0]))
  end

  defp split([], _space), do: []
  defp split(ids, _space) when length(ids) <= 510, do: [ids]

  defp split(ids, space) do
    head = Enum.take(ids, 510)

    cut =
      case Enum.find_index(Enum.reverse(head), &(&1 == space)) do
        nil -> 510
        index -> 510 - index
      end

    {section, rest} = Enum.split(ids, cut)
    [section | split(rest, space)]
  end

  defp prepare(text, voice, styles, phonemizer) when is_binary(text),
    do: prepare(%{text: text}, voice, styles, phonemizer)

  defp prepare(input, default_voice, styles, {module, options}) when is_map(input) do
    voice = Map.get(input, :voice, default_voice)
    speed = Map.get(input, :speed, 1.0)
    unless Map.has_key?(styles, voice), do: raise(ArgumentError, "voice is not loaded")

    unless is_number(speed) and speed >= 0.5 and speed <= 2.0,
      do: raise(ArgumentError, "speed must be between 0.5 and 2.0")

    phonemes =
      case input do
        %{phonemes: phonemes} when is_binary(phonemes) ->
          phonemes

        %{text: text} when is_binary(text) ->
          case module.phonemize(text, options) do
            {:ok, phonemes} ->
              phonemes

            {:error, reason} ->
              raise ArgumentError, "phoneme conversion failed: #{inspect(reason)}"
          end

        _ ->
          raise ArgumentError, "expected text or phonemes"
      end

    {phonemes, voice, speed}
  end

  defp prepare(_, _, _, _), do: raise(ArgumentError, "expected a string or input map")

  defp correct_phase(model) do
    unless Enum.any?(model.nodes, &(&1.name == @phase_node and &1.op_type == "Greater")),
      do: raise(ArgumentError, "Kokoro export does not match the phase correction")

    # The pinned export uses the wrong quadrant for atan2(0, negative).
    # Correction follows Transmuter's Apache-2.0 speech example.
    %{
      model
      | nodes:
          Enum.map(model.nodes, fn
            %{name: @phase_node} = node -> %{node | op_type: "GreaterOrEqual"}
            node -> node
          end)
    }
  end

  defp valid_voice?(name), do: is_binary(name) and Regex.match?(~r/\A[a-z]{2}_[a-z0-9_]+\z/, name)
end
