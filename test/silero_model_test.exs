if System.get_env("AUDIOFLOW_ML") == "1" do
  defmodule AudioFlow.SileroModelTest do
    use ExUnit.Case, async: false
    @moduletag :model
    @moduletag timeout: 120_000

    test "shared Silero matches independent ONNX Runtime values with separate stream states" do
      source =
        System.get_env("AUDIOFLOW_SILERO_MODEL") ||
          {:hf, "onnx-community/silero-vad", "onnx/model.onnx"}

      serving =
        AudioFlow.Silero.serving(source,
          load_options: [revision: "e71cae966052b992a7eca6b17738916ce0eca4ec"]
        )

      start_supervised!(
        AudioFlow.Models.child_spec(AudioFlow.TestSilero, serving,
          batch_size: 2,
          batch_timeout: 10
        )
      )

      expected =
        File.read!(Path.join(__DIR__, "fixtures/silero_reference.json"))
        |> Jason.decode!()
        |> Map.fetch!("probabilities")

      clients =
        for _ <- 1..2 do
          Task.async(fn ->
            {512, 16000, initial} = AudioFlow.Silero.init(serving: AudioFlow.TestSilero)

            Enum.map_reduce(0..3, initial, fn index, state ->
              pcm =
                for i <- 0..511, into: <<>> do
                  value = rem((index * 512 + i) * 7919, 65536) - 32768
                  <<value::little-signed-16>>
                end

              AudioFlow.Silero.predict(%AudioFlow.Audio{data: pcm, sample_rate: 16000}, state)
            end)
            |> elem(0)
          end)
        end

      for task <- clients do
        probabilities = Task.await(task, 120_000)

        for {actual, reference} <- Enum.zip(probabilities, expected),
            do: assert_in_delta(actual, reference, 0.00001)
      end
    end
  end
end
