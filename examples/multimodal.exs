# Run with AUDIOFLOW_ML=1. Image modes need ffmpeg and ffprobe.
# Modes: embed "text", image-embedding path/to/image.png, describe path/to/image.png
alias AudioFlow.{Image, Models, NxAdapter, Worker}

load_image = fn path ->
  {metadata, 0} =
    System.cmd("ffprobe", [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=width,height",
      "-of",
      "json",
      path
    ])

  %{"streams" => [%{"width" => width, "height" => height} | _]} = JSON.decode!(metadata)
  if width * height * 3 > 6_291_456, do: raise("Image exceeds the RGB byte limit")

  {rgb, 0} =
    System.cmd("ffmpeg", [
      "-v",
      "error",
      "-i",
      path,
      "-frames:v",
      "1",
      "-f",
      "rawvideo",
      "-pix_fmt",
      "rgb24",
      "pipe:1"
    ])

  image = %Image{data: rgb, width: width, height: height}
  if not Image.valid?(image), do: raise("Invalid RGB output")
  image
end

{serving, input, adapter_options} =
  case System.argv() do
    ["embed" | [_ | _] = words] ->
      {:ok, serving} =
        Models.text_embedding("sentence-transformers/all-MiniLM-L6-v2",
          load_options: [revision: "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"],
          model_options: [backend: EXLA.Backend],
          compile: [batch_size: 1, sequence_length: 256]
        )

      {serving, Enum.join(words, " "), [output: &NxAdapter.embedding/1]}

    ["image-embedding", path] ->
      {:ok, serving} =
        Models.clip_image_embedding("openai/clip-vit-base-patch32",
          load_options: [revision: "3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268"],
          model_options: [backend: EXLA.Backend],
          compile: [batch_size: 1]
        )

      {serving, load_image.(path),
       [input: &NxAdapter.image_input/1, output: &NxAdapter.embedding/1]}

    ["describe", path] ->
      {:ok, serving} =
        Models.image_captioning("Salesforce/blip-image-captioning-base",
          load_options: [revision: "82a37760796d32b1411fe092ab5d4e227313294b"],
          model_options: [backend: EXLA.Backend],
          generation_options: [max_new_tokens: 32, strategy: %{type: :greedy_search}],
          compile: [batch_size: 1]
        )

      {serving, load_image.(path),
       [input: &NxAdapter.image_input/1, output: &NxAdapter.captions/1]}

    _ ->
      raise "Usage: embed TEXT | image-embedding IMAGE | describe IMAGE"
  end

{:ok, supervisor} =
  Supervisor.start_link(
    [
      Models.child_spec(AudioFlow.ExampleModel, serving),
      {Worker,
       name: AudioFlow.ExampleModelWorker,
       adapter: {NxAdapter, [serving: AudioFlow.ExampleModel] ++ adapter_options},
       timeout_ms: 120_000}
    ],
    strategy: :one_for_one
  )

try do
  result =
    Worker.run(input, [worker: AudioFlow.ExampleModelWorker, timeout_ms: 120_000], fn value ->
      IO.puts(JSON.encode!(value))
      :ok
    end)

  if result != :ok, do: raise("Inference failed: #{inspect(result)}")
after
  Supervisor.stop(supervisor)
end
