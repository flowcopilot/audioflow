defmodule AudioFlowReleases.CallAgent do
  @moduledoc false
  # An AudioFlow.Agent for durable call tests. The call metadata has the test
  # process ("test"). With "block_on" set to a node name, the LLM on that node
  # never answers, so a test can stop the node during a turn.
  @behaviour AudioFlow.Agent
  alias AudioFlow.Adapters.Function
  alias AudioFlow.Audio

  @impl true
  def session_options(call) do
    test = call.metadata["test"]
    block = call.metadata["block_on"]

    [
      history: true,
      stt: {Function, run: fn _audio, emit -> emit.("hello") end},
      llm:
        {Function,
         run: fn messages, emit ->
           send(test, {:prompt, node(), Enum.map(messages, & &1.content)})
           if block == node(), do: Process.sleep(:infinity)
           emit.("reply #{length(messages)}")
         end},
      tts:
        {Function,
         run: fn _text, emit ->
           emit.(%Audio{data: :binary.copy(<<0x10, 0x27>>, 3200), sample_rate: 16_000})
         end}
    ]
  end

  @impl true
  def participant_options(_call) do
    [
      vad: {AudioFlowReleases.AmplitudeDetector, []},
      voice_input: [min_speech_ms: 20, min_silence_ms: 100, pre_roll_ms: 0]
    ]
  end
end
