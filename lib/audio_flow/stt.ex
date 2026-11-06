defmodule AudioFlow.STT do
  @moduledoc """
  The common speech-to-text interface.

  External services use `AudioFlow.STT.ReqLLM`, through ReqLLM. Local models use
  `AudioFlow.STT.Bumblebee`, through Bumblebee. Both are `AudioFlow.Adapter`
  modules with the same contract, so a session, a graph or
  `AudioFlow.transcribe/3` can use either one:

      {AudioFlow.STT.ReqLLM, model: "mistral:voxtral-mini-latest", language: "en"}
      {AudioFlow.STT.ReqLLM, model: "deepgram:nova-3", segments: true}
      {AudioFlow.STT.Bumblebee, model: "openai/whisper-small", language: "en"}

  Both take:

    * `:model` - required. A ReqLLM model input, or a Hugging Face repository.
    * `:language` - an ISO 639-1 code, or `nil` for detection.
    * `:segments` - when `true`, emit `AudioFlow.Transcript.Segment` values in
      place of text. Segment times are `nil` when the engine gives none.

  The input is one `AudioFlow.Audio` utterance at any sample rate. The adapter
  converts it to the format that the engine needs. The adapter emits after the
  engine finishes, as text strings or segments, never partial results. Other
  options are specific to the engine.
  """

  @common_schema [
    model: [type: :any, required: true, doc: "The model to use."],
    language: [type: {:or, [:string, nil]}, default: nil, doc: "ISO 639-1 language code."],
    segments: [type: :boolean, default: false, doc: "Emit timed segments."]
  ]

  @doc "Common options:\n\n" <> NimbleOptions.docs(@common_schema)
  def common_schema, do: @common_schema

  @doc """
  Split adapter options into validated common options and the other options.
  """
  def split_options!(options) do
    {common, rest} = Keyword.split(options, Keyword.keys(@common_schema))
    {Map.new(NimbleOptions.validate!(common, @common_schema)), rest}
  end

  @doc "Emit engine text or segments under the common `:segments` option."
  def emit(segments, text, segments?, emit) do
    outputs =
      if segments? and segments != [],
        do: Enum.reject(segments, &(&1.text == "")),
        else: if(String.trim(text) == "", do: [], else: [text])

    Enum.each(outputs, &(:ok = emit.(&1)))
  end
end
