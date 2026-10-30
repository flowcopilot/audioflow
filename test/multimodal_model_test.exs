if System.get_env("AUDIOFLOW_ML") == "1" do
  defmodule AudioFlow.MultimodalModelTest do
    use ExUnit.Case, async: false
    @moduletag :model
    @moduletag timeout: 600_000
    alias AudioFlow.{Image, Models, NxAdapter, Worker}

    setup_all do
      reference =
        File.read!(Path.join(__DIR__, "fixtures/multimodal_reference.json")) |> JSON.decode!()

      %{reference: reference}
    end

    test "two callers share a BERT serving with reference mean-pooled embeddings", %{
      reference: ref
    } do
      model = ref["text"]

      {:ok, serving} =
        Models.text_embedding(model["repository"],
          load_options: [revision: model["revision"]],
          model_options: [backend: EXLA.Backend],
          compile: [batch_size: 2, sequence_length: model["sequence_length"]]
        )

      start_supervised!(Models.child_spec(AudioFlow.TextEmbeddingTest, serving, batch_size: 2))

      worker =
        start_supervised!(
          {Worker,
           adapter:
             {NxAdapter, serving: AudioFlow.TextEmbeddingTest, output: &NxAdapter.embedding/1},
           max_concurrency: 2,
           timeout_ms: 120_000}
        )

      owner = self()

      tasks =
        for {input, index} <- Enum.with_index(model["inputs"]) do
          Task.async(fn ->
            Worker.run(input, [worker: worker, timeout_ms: 120_000], fn vector ->
              send(owner, {:embedding, index, vector})
              :ok
            end)
          end)
        end

      assert Enum.map(tasks, &Task.await(&1, 120_000)) == [:ok, :ok]

      for {expected, index} <- Enum.with_index(model["vectors"]) do
        assert_receive {:embedding, ^index, actual}
        assert length(actual) == 384
        assert_in_delta norm(actual), 1.0, 1.0e-5
        assert cosine(actual, expected) > 0.99999
      end
    end

    test "CLIP emits a projected image vector close to the independent reference", %{
      reference: ref
    } do
      model = ref["clip"]

      {:ok, serving} =
        Models.clip_image_embedding(model["repository"],
          load_options: [revision: model["revision"]],
          model_options: [backend: EXLA.Backend],
          compile: [batch_size: 1]
        )

      start_supervised!(Models.child_spec(AudioFlow.ImageEmbeddingTest, serving))

      assert :ok =
               NxAdapter.run(
                 image(ref),
                 [
                   serving: AudioFlow.ImageEmbeddingTest,
                   input: &NxAdapter.image_input/1,
                   output: &NxAdapter.embedding/1
                 ],
                 fn vector ->
                   send(self(), {:embedding, vector})
                   :ok
                 end
               )

      assert_receive {:embedding, actual}
      assert length(actual) == 512
      assert_in_delta norm(actual), 1.0, 1.0e-5
      assert cosine(actual, model["vector"]) > 0.99
    end

    test "a real BLIP image caption crosses a supervised session into speech output", %{
      reference: ref
    } do
      model = ref["caption"]

      {:ok, serving} =
        Models.image_captioning(model["repository"],
          load_options: [revision: model["revision"]],
          model_options: [backend: EXLA.Backend],
          generation_options: [
            max_new_tokens: model["max_new_tokens"],
            strategy: %{type: :greedy_search}
          ],
          compile: [batch_size: 1]
        )

      start_supervised!(Models.child_spec(AudioFlow.CaptionTest, serving))
      owner = self()

      options =
        AudioFlow.Adapters.Demo.options()
        |> Keyword.delete(:stt)
        |> Keyword.put(
          :vision,
          {NxAdapter,
           serving: AudioFlow.CaptionTest,
           input: &NxAdapter.image_input/1,
           output: &NxAdapter.captions/1}
        )
        |> Keyword.put(
          :llm,
          {AudioFlow.Adapters.Function,
           run: fn description, emit ->
             send(owner, {:prompt, description})
             emit.(description)
           end}
        )
        |> Keyword.put(:timeout_ms, 120_000)

      {:ok, session} = AudioFlow.start_session(options)
      on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
      {:ok, turn} = AudioFlow.submit(session, image(ref))
      assert_receive {AudioFlow, ^session, ^turn, {:description, caption}}, 120_000
      assert caption == model["text"]
      assert_receive {:prompt, ^caption}
      assert_receive {AudioFlow, ^session, ^turn, {:text, ^caption}}
      assert_receive {AudioFlow, ^session, ^turn, {:audio, %AudioFlow.Audio{}}}
      assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
    end

    defp image(reference) do
      path = Path.join([Mix.Project.deps_path(), "transmuter", reference["image"]["file"]])

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

      assert Base.encode16(:crypto.hash(:sha256, rgb), case: :lower) ==
               reference["image"]["rgb_sha256"]

      %Image{data: rgb, width: reference["image"]["width"], height: reference["image"]["height"]}
    end

    defp norm(vector), do: :math.sqrt(Enum.sum(Enum.map(vector, &(&1 * &1))))

    defp cosine(left, right),
      do:
        Enum.zip_with(left, right, &(&1 * &2)) |> Enum.sum() |> Kernel./(norm(left) * norm(right))
  end
end
