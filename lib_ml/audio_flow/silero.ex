defmodule AudioFlow.Silero do
  @moduledoc """
  Silero ONNX voice detection through shared Nx.Serving and Transmuter.

  The serving has shared weights. Each `AudioFlow.VoiceInput` keeps its own
  recurrent state and 64 context samples. This adapter accepts 16 kHz PCM,
  in frames of 512 samples. `serving/2` takes a local ONNX path or HF source.
  """
  @behaviour AudioFlow.VoiceDetector

  def serving(source, options \\ []) do
    model = Transmuter.load!(source, Keyword.get(options, :load_options, []))
    compiler_options = Keyword.get(options, :defn_options, compiler: EXLA)

    Nx.Serving.new(fn _ ->
      Nx.Defn.jit(
        fn inputs ->
          outputs =
            Transmuter.run(
              model,
              model.params,
              %{
                "input" => inputs.audio,
                "state" => Nx.transpose(inputs.state, axes: [1, 0, 2]),
                "sr" => Nx.tensor(16_000, type: :s64)
              },
              %{"sr" => Nx.tensor(16_000, type: :s64, backend: Nx.BinaryBackend)}
            )

          %{
            probability: outputs["output"],
            state: Nx.transpose(outputs["stateN"], axes: [1, 0, 2])
          }
        end,
        compiler_options
      )
    end)
  end

  @impl true
  def init(options) do
    state = %{
      serving: Keyword.fetch!(options, :serving),
      recurrent: Nx.broadcast(Nx.tensor(0.0), {2, 128}),
      context: :binary.copy(<<0, 0>>, 64)
    }

    {512, 16_000, state}
  end

  @impl true
  def predict(%AudioFlow.Audio{data: data, sample_rate: 16_000}, state)
      when byte_size(data) == 1024 do
    samples = for <<value::little-signed-16 <- state.context <> data>>, do: value / 32768
    batch = Nx.Batch.stack([%{audio: Nx.tensor(samples, type: :f32), state: state.recurrent}])
    result = Nx.Serving.batched_run(state.serving, batch)

    {Nx.to_number(Nx.squeeze(result.probability)),
     %{
       state
       | recurrent: Nx.squeeze(result.state, axes: [0]),
         context: binary_part(data, 896, 128)
     }}
  end
end
