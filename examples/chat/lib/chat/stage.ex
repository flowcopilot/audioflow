defmodule Chat.Stage do
  @moduledoc "Session adapter that runs the current model of one stage, so model switches keep the session."
  @behaviour AudioFlow.Adapter

  @impl true
  def run(input, options, emit) do
    stage = Keyword.fetch!(options, :stage)

    case Chat.Engine.adapter(stage) do
      nil -> {:error, {:model_loading, stage}}
      adapter -> AudioFlow.Adapter.run(adapter, input, emit)
    end
  end

  def session_options do
    [
      stt: {__MODULE__, stage: :stt},
      llm: {__MODULE__, stage: :llm},
      tts: {__MODULE__, stage: :tts},
      history: true,
      timeout_ms: 120_000,
      max_events: 4096
    ]
  end
end
