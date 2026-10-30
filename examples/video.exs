# AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 mix run examples/video.exs VIDEO.mp4 OUTPUT_DIR
# Sampled frames -> BLIP descriptions -> Qwen3 with history -> Kokoro PCM files.
# No microphone or sound device opens. All model services are shared across frames.
alias AudioFlow.{Models, NxAdapter, Video}
[path, output_dir] = System.argv()
interval = System.get_env("AUDIOFLOW_VIDEO_INTERVAL_MS", "1000") |> String.to_integer()
limit = System.get_env("AUDIOFLOW_VIDEO_FRAMES", "16") |> String.to_integer()
if interval <= 0 or limit <= 0, do: raise("Frame interval and count must be positive")

caption_source = "Salesforce/blip-image-captioning-base"
caption_revision = "82a37760796d32b1411fe092ab5d4e227313294b"
llm_source = "Qwen/Qwen3-0.6B"
llm_revision = "c1899de289a04d12100db370d81485cdf75e47ca"

{:ok, captions} =
  Models.image_captioning(caption_source,
    load_options: [revision: caption_revision],
    model_options: [backend: EXLA.Backend],
    generation_options: [max_new_tokens: 32, strategy: %{type: :greedy_search}],
    compile: [batch_size: 1]
  )

{:ok, llm} =
  Models.language_model(llm_source,
    load_options: [revision: llm_revision],
    model_options: [backend: EXLA.Backend],
    generation_options: [max_new_tokens: 64, strategy: %{type: :greedy_search}]
  )

tts = AudioFlow.Kokoro.serving()

{:ok, supervisor} =
  Supervisor.start_link(
    [
      Models.child_spec(AudioFlow.VideoCaptions, captions),
      Models.child_spec(AudioFlow.VideoLLM, llm),
      Models.child_spec(AudioFlow.VideoTTS, tts)
    ],
    strategy: :one_for_one
  )

system =
  "You describe sampled video frames. Base your answer on the supplied descriptions. Reply in one short sentence."

prompt = fn messages ->
  descriptions = Enum.filter(messages, &(&1.role == :user))
  current = List.last(descriptions).content
  previous = Enum.at(descriptions, -2)

  request =
    if previous do
      "Compare these sampled frames. Previous: #{previous.content}\nCurrent: #{current}\nDescribe the difference and mention both observations."
    else
      "This is the first sampled frame. Describe it: #{current}"
    end

  messages = List.update_at(messages, -1, &%{&1 | content: request})
  AudioFlow.Prompt.qwen3(messages, system: system)
end

options = [
  vision:
    {NxAdapter,
     serving: AudioFlow.VideoCaptions,
     input: &NxAdapter.image_input/1,
     output: &NxAdapter.captions/1},
  llm: {NxAdapter, serving: AudioFlow.VideoLLM, input: prompt, output: &NxAdapter.sentences/1},
  tts: {NxAdapter, serving: AudioFlow.VideoTTS, output: &AudioFlow.Kokoro.audio/1},
  history: true,
  timeout_ms: 120_000,
  max_events: 4096
]

{:ok, session} = AudioFlow.start_session(options)
File.mkdir_p!(output_dir)

source_hash =
  path
  |> File.stream!(65_536)
  |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, hash ->
    :crypto.hash_update(hash, chunk)
  end)
  |> :crypto.hash_final()
  |> Base.encode16(case: :lower)

collect = fn collect, turn, state ->
  receive do
    {AudioFlow, ^session, ^turn, {kind, text}} when kind in [:description, :text] ->
      collect.(collect, turn, Map.update!(state, kind, &[text | &1]))

    {AudioFlow, ^session, ^turn, {:audio, audio}} ->
      if state.sample_rate != nil and state.sample_rate != audio.sample_rate,
        do: raise("Output sample rate changed")

      collect.(collect, turn, %{
        state
        | pcm: [audio.data | state.pcm],
          sample_rate: audio.sample_rate
      })

    {AudioFlow, ^session, ^turn, {:done, metrics}} ->
      Map.put(state, :metrics, metrics)

    {AudioFlow, ^session, ^turn, {:error, reason, _}} ->
      raise "Frame failed: #{inspect(reason)}"

    {AudioFlow, ^session, ^turn, {:cancelled, _}} ->
      raise "Frame cancelled"
  after
    125_000 -> raise "Frame inference timed out"
  end
end

try do
  for {frame, index} <-
        Video.frames(path, interval_ms: interval, width: 384, height: 384)
        |> Stream.take(limit)
        |> Enum.with_index(1) do
    {:ok, turn} = AudioFlow.submit(session, frame)
    state = collect.(collect, turn, %{description: [], text: [], pcm: [], sample_rate: nil})
    pcm = state.pcm |> Enum.reverse() |> IO.iodata_to_binary()
    description = state.description |> Enum.reverse() |> Enum.join("")
    reply = state.text |> Enum.reverse() |> Enum.join("")

    metadata = %{
      video_sha256: source_hash,
      frame: index,
      pts_ns: frame.pts,
      description: description,
      reply: reply,
      sample_rate: state.sample_rate,
      bytes: byte_size(pcm),
      metrics: state.metrics,
      models: %{
        caption: %{
          repository: caption_source,
          revision: caption_revision,
          max_new_tokens: 32,
          strategy: "greedy_search"
        },
        llm: %{
          repository: llm_source,
          revision: llm_revision,
          max_new_tokens: 64,
          strategy: "greedy_search",
          prompt: "sampled_frame_pair_v1",
          system: system
        },
        tts: %{
          repository: "onnx-community/Kokoro-82M-v1.0-ONNX",
          revision: "1939ad2a8e416c0acfeecc08a694d14ef25f2231",
          voice: "af_heart"
        }
      }
    }

    File.write!(Path.join(output_dir, "#{index}.s16le"), pcm)
    File.write!(Path.join(output_dir, "#{index}.json"), JSON.encode!(metadata))
    IO.puts("#{frame.pts} ns: #{description} -> #{reply}")
  end
after
  AudioFlow.stop_session(session)
  Supervisor.stop(supervisor)
end
