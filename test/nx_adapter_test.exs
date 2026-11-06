if System.get_env("AUDIOFLOW_ML") == "1" do
  defmodule AudioFlow.NxAdapterTest do
    use ExUnit.Case, async: false
    alias AudioFlow.Audio
    alias AudioFlow.STT.Bumblebee

    test "a shared EXLA serving maps inputs and outputs across callers" do
      serving = Nx.Serving.jit(&Nx.multiply(&1, 2), compiler: EXLA)
      start_supervised!(AudioFlow.Models.child_spec(AudioFlow.TestServing, serving))

      options = [
        serving: AudioFlow.TestServing,
        input: fn number -> Nx.Batch.stack([Nx.tensor([number])]) end,
        output: &Nx.to_flat_list/1
      ]

      for number <- [3, 7] do
        assert :ok =
                 AudioFlow.NxAdapter.run(number, options, fn value ->
                   send(self(), {:result, value})
                   :ok
                 end)

        expected = number * 2
        assert_receive {:result, ^expected}
      end
    end

    test "local STT input keeps signed 16 kHz samples and resamples other rates" do
      audio = %Audio{
        data: <<-32_768::little-signed-16, 0::little-signed-16, 16_384::little-signed-16>>,
        sample_rate: 16_000
      }

      assert Nx.to_flat_list(Bumblebee.input(audio)) == [-1.0, 0.0, 0.5]

      eight_khz = %Audio{data: :binary.copy(<<0, 0>>, 800), sample_rate: 8000}
      assert Nx.size(Bumblebee.input(eight_khz)) == 1600
    end

    test "local STT reports a missing serving registry and rejects bad options" do
      audio = %Audio{data: <<0, 0>>, sample_rate: 16_000}
      emit = fn _ -> :ok end

      assert {:error, {:model_load, :servings_not_started}} =
               Bumblebee.run(audio, [model: "openai/whisper-tiny"], emit)

      assert_raise ArgumentError, ~r/English-only/, fn ->
        Bumblebee.run(
          audio,
          [model: "openai/whisper-tiny.en", language: "es"],
          emit
        )
      end

      assert_raise NimbleOptions.ValidationError, fn ->
        Bumblebee.run(audio, [model: "openai/whisper-tiny", unknown: 1], emit)
      end
    end

    test "synthesis PCM clamps model overshoot and emits little-endian samples" do
      output = %{audio: Nx.tensor([-1.5, -0.5, 0.0, 0.5, 1.5]), sampling_rate: 16_000}

      assert [%Audio{data: pcm, sample_rate: 16_000}] =
               AudioFlow.NxAdapter.speech_audio(output)

      assert pcm ==
               <<-32_768::little-signed-16, -16_384::little-signed-16, 0::little-signed-16,
                 16_384::little-signed-16, 32_767::little-signed-16>>

      chunks =
        AudioFlow.NxAdapter.speech_audio(%{
          audio: Nx.broadcast(0.0, {321}),
          sampling_rate: 16_000
        })

      assert Enum.map(chunks, &byte_size(&1.data)) == [640, 2]
    end

    test "RGB input preserves pixel order and channel order" do
      image = %AudioFlow.Image{data: <<255, 0, 0, 0, 255, 0>>, width: 2, height: 1}
      tensor = AudioFlow.NxAdapter.image_input(image)
      assert Nx.shape(tensor) == {1, 2, 3}
      assert Nx.type(tensor) == {:u, 8}
      assert Nx.to_list(tensor) == [[[255, 0, 0], [0, 255, 0]]]

      assert_raise ArgumentError, "invalid RGB image", fn ->
        AudioFlow.NxAdapter.image_input(%{image | width: 3})
      end
    end
  end
end
