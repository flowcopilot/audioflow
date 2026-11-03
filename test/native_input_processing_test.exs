defmodule AudioFlow.NativeInputProcessingTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Audio
  alias AudioFlow.PacketWorker
  alias AudioFlow.SmartTurn
  alias AudioFlow.SpeexDSP

  defp pcm(values), do: for(x <- values, into: <<>>, do: <<x::little-signed-16>>)

  defp energy(data),
    do: for(<<x::little-signed-16 <- data>>, reduce: 0.0, do: (sum -> sum + x * x))

  defp noise(i), do: rem(i * 7919 + i * i * 13, 16_001) - 8000

  @tag skip: is_nil(System.get_env("AUDIOFLOW_SPEEX_EXECUTABLE"))
  test "native stationary noise suppression reduces energy after adaptation" do
    {:ok, worker} =
      SpeexDSP.start_link(executable: System.fetch_env!("AUDIOFLOW_SPEEX_EXECUTABLE"))

    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)

    ratios =
      for frame <- 0..249 do
        data = pcm(for i <- 0..511, do: noise(frame * 512 + i))
        assert {:ok, clean} = PacketWorker.request(worker, data <> :binary.copy(<<0>>, 1024), 200)
        assert byte_size(clean) == 1024
        energy(clean) / energy(data)
      end

    assert Enum.sum(Enum.take(ratios, -50)) / 50 < 0.65
  end

  @tag skip: is_nil(System.get_env("AUDIOFLOW_SPEEX_EXECUTABLE"))
  test "native reference cancels a delayed scaled echo while retaining near-end speech" do
    {:ok, worker} =
      SpeexDSP.start_link(
        executable: System.fetch_env!("AUDIOFLOW_SPEEX_EXECUTABLE"),
        args: ["aec-only"]
      )

    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)

    ratios =
      for frame <- 0..399 do
        ref = pcm(for i <- 0..511, do: noise(frame * 512 + i))
        mic = pcm(for i <- 0..511, do: round(0.6 * noise(max(0, frame * 512 + i - 64))))
        {:ok, clean} = PacketWorker.request(worker, mic <> ref, 200)
        energy(clean) / energy(mic)
      end

    assert Enum.sum(Enum.take(ratios, -50)) / 50 < 0.1
    # No far-end reference: independent local audio must survive the linear AEC.
    mic = pcm(for i <- 0..511, do: round(5000 * :math.sin(i * 0.13)))
    {:ok, clean} = PacketWorker.request(worker, mic <> :binary.copy(<<0>>, 1024), 200)
    assert energy(clean) / energy(mic) > 0.4
  end

  @tag :model
  @tag skip: is_nil(System.get_env("AUDIOFLOW_SMART_TURN_MODEL"))
  test "pinned Smart Turn v3.1 CPU runs real ONNX inference deterministically" do
    model = System.fetch_env!("AUDIOFLOW_SMART_TURN_MODEL")

    assert :crypto.hash(:sha256, File.read!(model)) |> Base.encode16(case: :lower) ==
             "fb68d55c2d542ce79e44b12013bfd571e90df8594ab096d757198e851b0c6594"

    {:ok, worker} =
      SmartTurn.start_link(
        executable: System.fetch_env!("AUDIOFLOW_SMART_TURN_PYTHON"),
        args: [Application.app_dir(:audio_flow, "priv/audio_flow/smart_turn.py"), model]
      )

    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)
    data = pcm(for i <- 0..15_999, do: noise(i))
    audio = %Audio{sample_rate: 16_000, data: data}
    probability = SmartTurn.predict(audio, worker)
    assert probability >= 0 and probability <= 1
    # Captured independently using the pinned upstream WhisperFeatureExtractor recipe.
    assert_in_delta probability, 0.98183155, 1.0e-5
    assert_in_delta probability, SmartTurn.predict(audio, worker), 1.0e-6
    # Last-eight-second cropping is part of the public adapter contract.
    long = %{audio | data: :binary.copy(<<0, 0>>, 128_000) <> data}
    tail = %{audio | data: :binary.copy(<<0, 0>>, 112_000) <> data}
    assert_in_delta SmartTurn.predict(long, worker), SmartTurn.predict(tail, worker), 1.0e-6
  end
end
