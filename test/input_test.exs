if System.get_env("AUDIOFLOW_MEDIA") == "1" do
  defmodule AudioFlow.InputTest do
    use ExUnit.Case, async: true
    @moduletag capture_log: true
    @tag :tmp_dir
    test "stereo 48 kHz audio reaches a session as mono 16 kHz without changing pitch", %{
      tmp_dir: tmp_dir
    } do
      owner = self()

      options =
        Keyword.put(
          AudioFlow.Adapters.Demo.options(),
          :stt,
          {AudioFlow.Adapters.Function,
           run: fn audio, emit ->
             send(owner, {:resampled, audio})
             emit.("A tone")
           end}
        )

      {:ok, session} = AudioFlow.start_session(options)
      on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)

      stereo =
        for index <- 0..4799, into: <<>> do
          sample = round(12_000 * :math.sin(2 * :math.pi() * 1000 * index / 48000))
          <<sample::little-signed-16, sample::little-signed-16>>
        end

      location = Path.join(tmp_dir, "stereo.s16le")
      File.write!(location, stereo)

      source = %AudioFlow.PCMFileSource{
        location: location,
        chunk_bytes: 4000,
        stream_format: %Membrane.RawAudio{
          sample_rate: 48000,
          channels: 2,
          sample_format: :s16le
        }
      }

      {:ok, _supervisor, pipeline} =
        AudioFlow.InputPipeline.start_link(
          source: source,
          session: session,
          vad: {AudioFlow.Test.AlwaysSpeechDetector, []},
          endpoint_options: [min_speech_ms: 32, pre_roll_ms: 0]
        )

      assert_receive {AudioFlow.InputPipeline, ^pipeline, :end_of_stream}, 2000
      assert_receive {:resampled, %AudioFlow.Audio{sample_rate: 16000, data: pcm}}, 2000
      # 1600 real samples, padded to four 512-sample detector frames at EOS.
      assert byte_size(pcm) == 4096
      samples = for <<value::little-signed-16 <- pcm>>, do: value
      middle = Enum.slice(samples, 200, 1200)

      crossings =
        Enum.chunk_every(middle, 2, 1, :discard) |> Enum.count(fn [a, b] -> a < 0 != b < 0 end)

      assert crossings in 149..151
      assert Enum.max(middle) > 10_000
      assert_receive {AudioFlow, ^session, _, {:done, _}}, 2000
    end
  end
end
