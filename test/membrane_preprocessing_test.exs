if System.get_env("AUDIOFLOW_MEDIA") == "1" do
  defmodule AudioFlow.MembranePreprocessingTest do
    use ExUnit.Case, async: true
    alias AudioFlow.{Audio, PCMSink}

    defmodule CancelReference do
      def init(_, 16000, 512), do: nil

      def process(audio, reference, state) do
        # A deterministic filter fixture: the real native cancellation is tested separately.
        if audio.data == reference.data,
          do: {%{audio | data: :binary.copy(<<0>>, byte_size(audio.data))}, state},
          else: {audio, state}
      end
    end

    test "Membrane sink delivers aligned references to preprocessing before VAD" do
      options = %{
        session: self(),
        vad: {AudioFlow.Test.FrameDetector, []},
        endpoint_options: [min_speech_ms: 32, preprocessor: {CancelReference, []}]
      }

      {[], state} = PCMSink.handle_init(nil, options)
      format = %Membrane.RawAudio{sample_rate: 16000, channels: 1, sample_format: :s16le}
      {[], state} = PCMSink.handle_stream_format(:input, format, nil, state)
      pcm = :binary.copy(<<32000::little-signed-16>>, 512)

      {[], state} =
        PCMSink.handle_parent_notification(
          {:audio_flow_reference, %Audio{data: pcm, sample_rate: 16000}},
          nil,
          state
        )

      {[], state} = PCMSink.handle_buffer(:input, %Membrane.Buffer{payload: pcm}, nil, state)
      refute state.input.speaking?
      assert state.reference == <<>>

      assert_raise ArgumentError, fn ->
        PCMSink.handle_parent_notification(
          {:audio_flow_reference, %Audio{data: :binary.copy(pcm, 32), sample_rate: 16000}},
          nil,
          state
        )
      end
    end
  end
end
