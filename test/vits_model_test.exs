if System.get_env("AUDIOFLOW_ML") == "1" do
  defmodule AudioFlow.VitsModelTest do
    use ExUnit.Case, async: false
    @moduletag :model
    @moduletag timeout: 300_000

    test "native VITS produces non-silent PCM with the reference duration" do
      serving =
        AudioFlow.Models.text_to_speech("Xenova/mms-tts-eng",
          revision: "3f8955a2adbd6487ce57420620d4916de22b9dac",
          noise: false
        )

      start_supervised!(AudioFlow.Models.child_spec(AudioFlow.TestVits, serving))
      result = Nx.Serving.batched_run(AudioFlow.TestVits, "Hello, my dog is cute.")
      assert result.sampling_rate == 16000
      # Independent PyTorch reference in the pinned Transmuter speech guide.
      assert Nx.size(result.audio) == 33024
      chunks = AudioFlow.NxAdapter.speech_audio(result)
      assert Enum.all?(chunks, &AudioFlow.Audio.valid?/1)
      pcm = Enum.map_join(chunks, & &1.data)
      assert byte_size(pcm) == 66048
      samples = for <<sample::little-signed-16 <- pcm>>, do: sample
      assert Enum.max(samples) > 1000
      assert Enum.min(samples) < -1000
    end
  end
end
