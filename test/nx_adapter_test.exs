if System.get_env("AUDIOFLOW_ML") == "1" do
  defmodule AudioFlow.NxAdapterTest do
    use ExUnit.Case, async: false

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

    test "PCM conversion preserves signed sample values and rejects other rates" do
      audio = %AudioFlow.Audio{
        data: <<-32768::little-signed-16, 0::little-signed-16, 16384::little-signed-16>>,
        sample_rate: 16000
      }

      assert Nx.to_flat_list(AudioFlow.NxAdapter.whisper_input(audio)) == [-1.0, 0.0, 0.5]

      assert_raise ArgumentError, fn ->
        AudioFlow.NxAdapter.whisper_input(%{audio | sample_rate: 8000})
      end
    end

    test "synthesis PCM clamps model overshoot and emits little-endian samples" do
      output = %{audio: Nx.tensor([-1.5, -0.5, 0.0, 0.5, 1.5]), sampling_rate: 16000}

      assert [%AudioFlow.Audio{data: pcm, sample_rate: 16000}] =
               AudioFlow.NxAdapter.speech_audio(output)

      assert pcm ==
               <<-32768::little-signed-16, -16384::little-signed-16, 0::little-signed-16,
                 16384::little-signed-16, 32767::little-signed-16>>

      chunks =
        AudioFlow.NxAdapter.speech_audio(%{audio: Nx.broadcast(0.0, {321}), sampling_rate: 16000})

      assert Enum.map(chunks, &byte_size(&1.data)) == [640, 2]
    end
  end
end
