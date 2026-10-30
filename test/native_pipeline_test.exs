if System.get_env("AUDIOFLOW_ML") == "1" and System.get_env("AUDIOFLOW_MEDIA") == "1" do
  defmodule AudioFlow.NativePipelineTest do
    use ExUnit.Case, async: false
    @moduletag :pipeline_model
    @moduletag :tmp_dir
    @moduletag timeout: 600_000
    @moduletag capture_log: true
    alias AudioFlow.{Audio, Models, NxAdapter, Playback}
    alias Membrane.Testing.Notification

    test "recorded speech crosses the real Membrane, Whisper, Qwen3, and Kokoro path", %{
      tmp_dir: tmp_dir
    } do
      fixture =
        Path.join([
          Mix.Project.deps_path(),
          "transmuter",
          "test",
          "fixtures",
          "librispeech_0.flac"
        ])

      {pcm, 0} =
        System.cmd("ffmpeg", [
          "-v",
          "error",
          "-i",
          fixture,
          "-ac",
          "1",
          "-ar",
          "16000",
          "-f",
          "s16le",
          "pipe:1"
        ])

      input_path = Path.join(tmp_dir, "speech.s16le")
      File.write!(input_path, pcm)

      {:ok, whisper} =
        Models.whisper("openai/whisper-tiny",
          load_options: [revision: "169d4a4341b33bc18d8881c4b69c2e104e1cc0af"],
          model_options: [backend: EXLA.Backend]
        )

      {:ok, llm} =
        Models.language_model("Qwen/Qwen3-0.6B",
          load_options: [revision: "c1899de289a04d12100db370d81485cdf75e47ca"],
          model_options: [backend: EXLA.Backend],
          generation_options: [max_new_tokens: 64, strategy: %{type: :greedy_search}]
        )

      kokoro = AudioFlow.Kokoro.serving()

      silero_source =
        System.get_env("AUDIOFLOW_SILERO_MODEL") ||
          {:hf, "onnx-community/silero-vad", "onnx/model.onnx"}

      silero =
        AudioFlow.Silero.serving(silero_source,
          load_options: [revision: "e71cae966052b992a7eca6b17738916ce0eca4ec"]
        )

      start_supervised!(Models.child_spec(AudioFlow.NativeWhisper, whisper))
      start_supervised!(Models.child_spec(AudioFlow.NativeLLM, llm))
      start_supervised!(Models.child_spec(AudioFlow.NativeTTS, kokoro))
      start_supervised!(Models.child_spec(AudioFlow.NativeVAD, silero))
      playback = start_supervised!({Playback, sink: Membrane.Testing.Sink, observer: self()})

      options = [
        stt:
          {NxAdapter,
           serving: AudioFlow.NativeWhisper,
           input: &NxAdapter.whisper_input/1,
           output: &NxAdapter.transcript/1},
        llm:
          {NxAdapter,
           serving: AudioFlow.NativeLLM,
           input: &AudioFlow.Prompt.qwen3/1,
           output: &NxAdapter.sentences/1},
        tts: {NxAdapter, serving: AudioFlow.NativeTTS, output: &AudioFlow.Kokoro.audio/1},
        output: {Playback, playback},
        timeout_ms: 120_000,
        max_events: 4096
      ]

      {:ok, session} = AudioFlow.start_session(options)
      on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)

      source = %AudioFlow.PCMFileSource{
        location: input_path,
        stream_format: %Membrane.RawAudio{sample_format: :s16le, sample_rate: 16000, channels: 1}
      }

      {:ok, _supervisor, input} =
        AudioFlow.InputPipeline.start_link(
          source: source,
          session: session,
          vad: {AudioFlow.Silero, serving: AudioFlow.NativeVAD}
        )

      state =
        await(
          session,
          playback,
          input,
          %{
            input_done?: false,
            done?: false,
            drained?: false,
            accepted: 0,
            transcripts: [],
            texts: [],
            audio: [],
            delivered_bytes: 0,
            metrics: nil
          },
          System.monotonic_time(:millisecond) + 180_000
        )

      transcript = state.transcripts |> Enum.reverse() |> Enum.join("")
      reply = state.texts |> Enum.reverse() |> Enum.join("")
      audio = state.audio |> Enum.reverse() |> IO.iodata_to_binary()
      assert state.accepted == 1
      assert String.contains?(String.downcase(transcript), "middle classes")
      assert String.contains?(String.downcase(transcript), "gospel")
      assert String.trim(reply) != ""
      refute String.contains?(reply, "<think>")
      assert byte_size(audio) > 2400
      assert state.delivered_bytes == byte_size(audio)
      assert Enum.any?(for(<<sample::little-signed-16 <- audio>>, do: abs(sample) > 1000))
      artifacts = System.get_env("AUDIOFLOW_PIPELINE_ARTIFACT_DIR", tmp_dir)
      File.mkdir_p!(artifacts)
      File.write!(Path.join(artifacts, "transcript.txt"), transcript)
      File.write!(Path.join(artifacts, "reply.txt"), reply)
      File.write!(Path.join(artifacts, "output.s16le"), audio)
      File.write!(Path.join(artifacts, "metrics.json"), JSON.encode!(state.metrics))
    end

    defp await(
           _session,
           _playback,
           _input,
           %{input_done?: true, done?: true, drained?: true} = state,
           _deadline
         ),
         do: state

    defp await(session, playback, input, state, deadline) do
      remaining = max(0, deadline - System.monotonic_time(:millisecond))

      state =
        receive do
          {AudioFlow.InputPipeline, ^input, :end_of_stream} ->
            %{state | input_done?: true}

          {AudioFlow.InputPipeline, ^input, {:audio_flow_input, {:ok, _turn}}} ->
            %{state | accepted: state.accepted + 1}

          {AudioFlow.InputPipeline, ^input, {:audio_flow_input, {:error, reason}}} ->
            flunk("input failed: #{inspect(reason)}")

          {AudioFlow, ^session, _, {:transcript, text}} ->
            %{state | transcripts: [text | state.transcripts]}

          {AudioFlow, ^session, _, {:text, text}} ->
            %{state | texts: [text | state.texts]}

          {AudioFlow, ^session, _, {:audio, %Audio{data: pcm, sample_rate: rate}}} ->
            assert rate == 24000
            %{state | audio: [pcm | state.audio]}

          {AudioFlow, ^session, _, {:done, metrics}} ->
            %{state | done?: true, metrics: metrics}

          {AudioFlow, ^session, _, {:error, reason, _}} ->
            flunk("inference failed: #{inspect(reason)}")

          {Playback, ^playback, {^session, _}, :drained} ->
            %{state | drained?: true}

          {Playback, ^playback, _,
           {:sink_notification, :sink,
            %Notification{payload: {:buffer, %Membrane.Buffer{payload: pcm}}}}} ->
            %{state | delivered_bytes: state.delivered_bytes + byte_size(pcm)}

          {Playback, ^playback, _, {:failed, reason}} ->
            flunk("output failed: #{inspect(reason)}")

          _ ->
            state
        after
          remaining -> flunk("native pipeline timed out")
        end

      await(session, playback, input, state, deadline)
    end
  end
end
