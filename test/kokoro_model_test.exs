if System.get_env("AUDIOFLOW_ML") == "1" do
  defmodule AudioFlow.KokoroModelTest do
    use ExUnit.Case, async: false
    @moduletag :model
    @moduletag timeout: 300_000

    test "shared Kokoro matches reference durations for voices, speed, and text input" do
      serving = AudioFlow.Kokoro.serving(voices: ["af_heart", "am_adam"])
      start_supervised!(AudioFlow.Models.child_spec(AudioFlow.TestKokoro, serving))

      references =
        File.read!(Path.join(__DIR__, "fixtures/kokoro_reference.json")) |> Jason.decode!()

      for reference <- references["cases"] do
        input = %{voice: reference["voice"], speed: reference["speed"]}

        input =
          if reference["text"],
            do: Map.put(input, :text, reference["text"]),
            else: Map.put(input, :phonemes, reference["phonemes"])

        results = Nx.Serving.batched_run(AudioFlow.TestKokoro, input) |> Enum.to_list()
        assert [result] = results
        assert result.sampling_rate == 24_000
        assert Nx.size(result.audio) == reference["samples"]
        invalid = Nx.logical_or(Nx.is_nan(result.audio), Nx.is_infinity(result.audio))
        assert Nx.to_number(Nx.any(invalid)) == 0
        chunks = AudioFlow.Kokoro.audio(results) |> Enum.to_list()
        assert Enum.all?(chunks, &AudioFlow.Audio.valid?/1)
        assert Enum.sum(Enum.map(chunks, &byte_size(&1.data))) == reference["samples"] * 2
        pcm = Enum.map_join(chunks, & &1.data)
        assert Enum.any?(for(<<sample::little-signed-16 <- pcm>>, do: abs(sample) > 1000))
      end

      assert_raise ArgumentError, ~r/voice is not loaded/, fn ->
        Nx.Serving.batched_run(AudioFlow.TestKokoro, %{phonemes: "həlˈO.", voice: "missing"})
      end

      assert_raise ArgumentError, ~r/speed/, fn ->
        Nx.Serving.batched_run(AudioFlow.TestKokoro, %{phonemes: "həlˈO.", speed: 0})
      end

      # Exercise the actual turn worker and PCM mapper against the same shared model.
      options =
        Keyword.put(
          AudioFlow.Adapters.Demo.options(),
          :tts,
          {AudioFlow.NxAdapter, serving: AudioFlow.TestKokoro, output: &AudioFlow.Kokoro.audio/1}
        )

      {:ok, session} = AudioFlow.start_session(options)

      try do
        {:ok, turn} =
          AudioFlow.submit(session, %AudioFlow.Audio{data: <<0, 0>>, sample_rate: 16000})

        assert_receive {AudioFlow, ^session, ^turn,
                        {:audio, %AudioFlow.Audio{sample_rate: 24000}}},
                       60_000

        assert_receive {AudioFlow, ^session, ^turn, {:done, _}}, 60_000
      after
        AudioFlow.stop_session(session)
      end
    end
  end
end
