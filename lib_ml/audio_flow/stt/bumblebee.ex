defmodule AudioFlow.STT.Bumblebee do
  @moduledoc """
  Speech-to-text with a local Whisper model, through Bumblebee.

  This adapter follows the common `AudioFlow.STT` interface. `:model` is a
  Hugging Face Whisper repository, for example `"openai/whisper-small"`.

      {AudioFlow.STT.Bumblebee, model: "openai/whisper-small", language: "en"}

  Bumblebee fixes the language when it builds a serving. So the adapter loads
  one shared serving for each model, revision, language and serving options,
  through `AudioFlow.Servings`, on first use. All sessions share it. Add
  `AudioFlow.Servings` to the inference children. Call `preload/1` at startup,
  because the first load can take minutes. English-only `.en` models accept
  only `nil` or `"en"`.

  Other options:

    * `:revision` - the repository revision.
    * `:serving_options` - options for `AudioFlow.Models.whisper/2`, for
      example `model_options: [backend: EXLA.Backend]` or
      `defn_options: [compiler: EMLX]`. They default to EXLA.

  The input is converted to 16 kHz with `AudioFlow.Resampler`. With
  `segments: true`, each Whisper chunk becomes a segment without times: with
  the pinned Bumblebee 0.8.0 and EXLA 1.0.0, Whisper `timestamps: :segments`
  fails to compile. `AudioFlow.transcribe/3` gives these segments their
  section times.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Audio
  alias AudioFlow.STT
  alias AudioFlow.Transcript.Segment

  @options_schema [
    revision: [type: {:or, [:string, nil]}, default: nil],
    serving_options: [type: :keyword_list, default: [model_options: [backend: EXLA.Backend]]]
  ]

  @impl true
  def run(%Audio{} = audio, options, emit) do
    unless Audio.valid?(audio) and audio.data != <<>>,
      do: raise(ArgumentError, "expected nonempty mono s16le PCM")

    {common, serving} = options!(options)

    case fetch(common, serving) do
      {:ok, name} ->
        %{chunks: chunks} = Nx.Serving.batched_run(name, input(audio))
        segments = for chunk <- chunks, do: %Segment{text: String.trim(chunk.text)}
        STT.emit(segments, Enum.map_join(chunks, & &1.text), common.segments, emit)

      {:error, reason} ->
        {:error, {:model_load, reason}}
    end
  end

  def run(_input, _options, _emit), do: raise(ArgumentError, "expected AudioFlow.Audio input")

  @doc "Load the serving for these adapter options. Returns `{:ok, name}` or `{:error, reason}`."
  def preload(options) do
    {common, serving} = options!(options)
    fetch(common, serving)
  end

  @doc "Stop the serving for these adapter options. The next use loads it again."
  def release(options) do
    {common, serving} = options!(options)
    AudioFlow.Servings.release(key(common, serving))
  end

  @doc "Convert PCM at any sample rate to the 16 kHz float tensor that Whisper needs."
  def input(%Audio{} = audio) do
    %Audio{data: data} = AudioFlow.Resampler.convert(audio, 16_000)
    samples = for <<sample::little-signed-16 <- data>>, do: sample / 32_768
    Nx.tensor(samples, type: :f32)
  end

  defp options!(options) do
    {common, rest} = STT.split_options!(options)
    unless is_binary(common.model), do: raise(ArgumentError, "model must be a repository name")
    {common, Map.new(NimbleOptions.validate!(rest, @options_schema))}
  end

  defp key(common, serving),
    do: {:whisper, common.model, serving.revision, common.language, serving.serving_options}

  defp fetch(common, serving) do
    language_options =
      AudioFlow.ModelLanguages.whisper_options!(common.model, common.language || "auto")

    key = key(common, serving)
    load_options = if serving.revision, do: [revision: serving.revision], else: []

    if Process.whereis(AudioFlow.Servings.Loader) == nil do
      {:error, :servings_not_started}
    else
      AudioFlow.Servings.fetch(key, fn ->
        AudioFlow.Models.whisper(
          common.model,
          [load_options: load_options] ++ serving.serving_options ++ language_options
        )
      end)
    end
  end
end
