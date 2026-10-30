defmodule AudioFlow.Adapters.Demo do
  @moduledoc "Synthetic pipeline for setup checks. Does not perform speech inference."
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Audio

  def options do
    [
      stt: {__MODULE__, [stage: :stt]},
      llm: {__MODULE__, [stage: :llm]},
      tts: {__MODULE__, [stage: :tts]}
    ]
  end

  @impl true
  def run(input, options, emit) do
    case Keyword.fetch!(options, :stage) do
      :stt -> emit.("Hello")
      :llm -> emit.("You said: #{input}.")
      :tts -> emit.(%Audio{data: :binary.copy(<<0, 0>>, 1600), sample_rate: 16_000})
    end
  end
end
