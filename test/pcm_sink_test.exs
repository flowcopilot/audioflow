if System.get_env("AUDIOFLOW_MEDIA") == "1" do
  defmodule AudioFlow.PCMSinkTest do
    use ExUnit.Case, async: true
    @moduletag capture_log: true
    import Membrane.ChildrenSpec
    import Membrane.Testing.Assertions

    test "Membrane frames interrupt a reply and submit one complete utterance" do
      owner = self()

      options =
        Keyword.merge(AudioFlow.Adapters.Demo.options(),
          stt:
            {AudioFlow.Adapters.Function,
             run: fn audio, emit ->
               send(owner, {:transcribed, audio})
               emit.("Hello")
             end},
          llm:
            {AudioFlow.Adapters.Function,
             run: fn _, emit ->
               send(owner, {:generating, self()})

               receive do
                 :continue -> emit.("A reply.")
               end
             end}
        )

      {:ok, session} = AudioFlow.start_session(options)
      on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
      original = %AudioFlow.Audio{data: <<0, 0>>, sample_rate: 16000}
      {:ok, first_turn} = AudioFlow.submit(session, original)
      assert_receive {:transcribed, ^original}
      assert_receive {:generating, first_worker}
      monitor = Process.monitor(first_worker)

      speech = :binary.copy(<<32000::little-signed-16>>, 512 * 3)
      silence = :binary.copy(<<0, 0>>, 512 * 2)
      data = speech <> silence
      parts = [binary_part(data, 0, 300), binary_part(data, 300, byte_size(data) - 300)]

      spec =
        child(:source, %Membrane.Testing.Source{
          output: parts,
          stream_format: %Membrane.RawAudio{
            sample_format: :s16le,
            channels: 1,
            sample_rate: 16000
          }
        })
        |> child(:input, %AudioFlow.PCMSink{
          session: session,
          vad: {AudioFlow.Test.FrameDetector, []},
          endpoint_options: [pre_roll_ms: 0, min_silence_ms: 64]
        })

      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      assert_pipeline_notified(pipeline, :input, {:audio_flow_speech_started, ^session})
      assert_receive {AudioFlow, ^session, ^first_turn, {:cancelled, _}}
      assert_receive {:DOWN, ^monitor, :process, ^first_worker, :killed}
      assert_pipeline_notified(pipeline, :input, {:audio_flow_input, {:ok, next_turn}})
      assert_receive {:transcribed, %AudioFlow.Audio{data: ^data, sample_rate: 16000}}
      assert_receive {:generating, next_worker}
      send(next_worker, :continue)
      assert_receive {AudioFlow, ^session, ^next_turn, {:audio, %AudioFlow.Audio{}}}
      assert_receive {AudioFlow, ^session, ^next_turn, {:done, _}}
      assert_end_of_stream(pipeline, :input)
    end
  end
end
