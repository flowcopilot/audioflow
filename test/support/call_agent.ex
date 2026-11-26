if System.get_env("AUDIOFLOW_SFU") == "1" do
  defmodule AudioFlow.Test.CallAgent do
    @moduledoc false
    # An AudioFlow.Agent for call tests. The call metadata carries the test
    # process ("test") for the stub SFU and the members ("others").
    @behaviour AudioFlow.Agent
    alias AudioFlow.Adapters.Function
    alias AudioFlow.Audio

    defmodule Detector do
      @moduledoc false
      def init(_), do: {320, 16_000, nil}

      def predict(%Audio{data: data}, state) do
        speech = for(<<x::little-signed-16 <- data>>, do: abs(x)) |> Enum.max()
        {if(speech > 1000, do: 1.0, else: 0.0), state}
      end
    end

    @impl true
    def session_options(call) do
      test = call.metadata["test"]

      [
        history: true,
        stt: {Function, run: fn _audio, emit -> emit.("hello") end},
        llm:
          {Function,
           run: fn messages, emit ->
             send(test, {:prompt, messages})
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
    def participant_options(call) do
      [
        vad: {Detector, []},
        voice_input: [min_speech_ms: 20, min_silence_ms: 60, pre_roll_ms: 0],
        gap_timeout_ms: 50,
        join: [test: call.metadata["test"], others: call.metadata["others"] || []]
      ]
    end
  end
end
