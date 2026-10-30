defmodule AudioFlow.Graph.Nodes.Models do
  @moduledoc """
  Graph nodes for the native models of `AudioFlow.Models` and `AudioFlow.Kokoro`.

  Each node names a model. The model loads on the first turn that uses it,
  through `AudioFlow.Servings`, and all sessions share it. The first turn can
  take minutes to download and compile, so set a graph `"timeout_ms"` that
  allows for it; a timed-out turn does not stop the load. Models run with
  EXLA. Pinned revisions come from the examples; other models use their
  current revision.

  Kokoro needs the `espeak-ng` executable. American voices (`af_`, `am_`)
  use American English phonemes, and British voices (`bf_`, `bm_`) use
  British English phonemes.
  """
  @behaviour AudioFlow.Graph.Node
  alias AudioFlow.{Kokoro, Models, NxAdapter}

  @whisper %{
    "openai/whisper-tiny" => "169d4a4341b33bc18d8881c4b69c2e104e1cc0af",
    "openai/whisper-tiny.en" => nil,
    "openai/whisper-base" => nil,
    "openai/whisper-base.en" => nil,
    "openai/whisper-small" => "973afd24965f72e36ca33b3055d56a652f456b4d",
    "openai/whisper-small.en" => nil,
    "openai/whisper-medium" => nil,
    "openai/whisper-medium.en" => nil,
    "openai/whisper-large-v3" => nil,
    "openai/whisper-large-v3-turbo" => "41f01f3fe87f28c78e2fbf8b568835947dd65ed9"
  }
  @qwen3 %{
    "Qwen/Qwen3-0.6B" => "c1899de289a04d12100db370d81485cdf75e47ca",
    "Qwen/Qwen3-1.7B" => nil,
    "Qwen/Qwen3-4B" => nil,
    "Qwen/Qwen3-8B" => nil
  }
  @kokoro_repository "onnx-community/Kokoro-82M-v1.0-ONNX"
  @kokoro_revision "1939ad2a8e416c0acfeecc08a694d14ef25f2231"
  @voices ~w(af_heart af_alloy af_aoede af_bella af_jessica af_kore af_nicole af_nova af_river
             af_sarah af_sky am_adam am_echo am_eric am_fenrir am_liam am_michael am_onyx am_puck
             am_santa bf_alice bf_emma bf_isabella bf_lily bm_daniel bm_fable bm_george bm_lewis)
  @vits %{"Xenova/mms-tts-eng" => "3f8955a2adbd6487ce57420620d4916de22b9dac"}
  @blip %{
    "Salesforce/blip-image-captioning-base" => "82a37760796d32b1411fe092ab5d4e227313294b",
    "Salesforce/blip-image-captioning-large" => nil
  }
  @clip %{
    "openai/clip-vit-base-patch32" => "3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268",
    "openai/clip-vit-large-patch14" => nil
  }
  @embedding %{
    "sentence-transformers/all-MiniLM-L6-v2" => "1110a243fdf4706b3f48f1d95db1a4f5529b4d41",
    "sentence-transformers/all-mpnet-base-v2" => nil
  }

  @impl true
  def nodes do
    [
      %{
        type: "whisper.stt",
        title: "Whisper",
        description: "Speech recognition. Needs 16 kHz mono PCM.",
        input: :audio,
        output: :text,
        event: :transcript,
        options: [model(@whisper, "openai/whisper-tiny")]
      },
      %{
        type: "qwen3.llm",
        title: "Qwen3",
        description: "Text generation with the Qwen3 chat format. Accepts history.",
        input: :text,
        output: :text,
        history: true,
        options: [
          model(@qwen3, "Qwen/Qwen3-0.6B"),
          %{name: :system, type: :string, description: "System instruction."},
          max_new_tokens(128)
        ]
      },
      %{
        type: "bumblebee.llm",
        title: "Bumblebee LLM",
        description: "Text generation for a repository that Bumblebee supports. Plain prompt.",
        input: :text,
        output: :text,
        options: [
          %{name: :model, type: :string, required: true, description: "Hugging Face repository."},
          %{name: :revision, type: :string, description: "Git revision of the repository."},
          max_new_tokens(128)
        ]
      },
      %{
        type: "kokoro.tts",
        title: "Kokoro",
        description: "Speech synthesis at 24 kHz. Needs espeak-ng.",
        input: :text,
        output: :audio,
        input_mode: :stream,
        options: [
          %{name: :voice, type: {:enum, @voices}, default: "af_heart", description: "Voice."}
        ]
      },
      %{
        type: "vits.tts",
        title: "VITS",
        description: "Speech synthesis with an MMS VITS model.",
        input: :text,
        output: :audio,
        input_mode: :stream,
        options: [model(@vits, "Xenova/mms-tts-eng")]
      },
      %{
        type: "blip.vision",
        title: "BLIP captions",
        description: "Describes an image in one sentence.",
        input: :image,
        output: :text,
        event: :description,
        options: [model(@blip, "Salesforce/blip-image-captioning-base"), max_new_tokens(32)]
      },
      %{
        type: "clip.embedding",
        title: "CLIP image embedding",
        description: "A normalized image vector in the joint text-image space.",
        input: :image,
        output: :vector,
        options: [model(@clip, "openai/clip-vit-base-patch32")]
      },
      %{
        type: "text.embedding",
        title: "Text embedding",
        description: "A normalized, mean-pooled sentence vector.",
        input: :text,
        output: :vector,
        options: [model(@embedding, "sentence-transformers/all-MiniLM-L6-v2")]
      }
    ]
  end

  defp model(models, default),
    do: %{
      name: :model,
      type: {:enum, models |> Map.keys() |> Enum.sort()},
      default: default,
      description: "Hugging Face repository."
    }

  defp max_new_tokens(default),
    do: %{name: :max_new_tokens, type: :integer, default: default, description: "Reply limit."}

  @impl true
  def adapter("whisper.stt", %{model: model}) do
    serving(
      {:whisper, model},
      fn ->
        Models.whisper(model, load_options: load(@whisper, model), model_options: exla())
      end,
      input: &NxAdapter.whisper_input/1,
      output: &NxAdapter.transcript/1
    )
  end

  def adapter("qwen3.llm", options) do
    prompt_options = if options[:system], do: [system: options.system], else: []

    serving(
      {:llm, options.model, options.max_new_tokens},
      fn ->
        language_model(options.model, load(@qwen3, options.model), options.max_new_tokens)
      end,
      input: &AudioFlow.Prompt.qwen3(&1, prompt_options),
      output: &NxAdapter.sentences/1
    )
  end

  def adapter("bumblebee.llm", options) do
    revision = if options[:revision], do: [revision: options.revision], else: []

    serving(
      {:llm, options.model, options[:revision], options.max_new_tokens},
      fn -> language_model(options.model, revision, options.max_new_tokens) end,
      output: &NxAdapter.sentences/1
    )
  end

  def adapter("kokoro.tts", %{voice: voice}) do
    {language, voices} =
      if String.starts_with?(voice, "b"),
        do: {"en-gb", Enum.filter(@voices, &String.starts_with?(&1, "b"))},
        else: {"en-us", Enum.filter(@voices, &String.starts_with?(&1, "a"))}

    serving(
      {:kokoro, language},
      fn ->
        Kokoro.serving(
          source: {:hf, @kokoro_repository},
          load_options: [revision: @kokoro_revision],
          voices: voices,
          phonemizer: {AudioFlow.Phonemizers.ESpeak, [language: language]}
        )
      end,
      input: &%{text: &1, voice: voice, speed: 1.0},
      output: &Kokoro.audio/1
    )
  end

  def adapter("vits.tts", %{model: model}) do
    serving(
      {:vits, model},
      fn -> Models.text_to_speech(model, load(@vits, model)) end,
      output: &NxAdapter.speech_audio/1
    )
  end

  def adapter("blip.vision", options) do
    serving(
      {:blip, options.model, options.max_new_tokens},
      fn ->
        Models.image_captioning(options.model,
          load_options: load(@blip, options.model),
          model_options: exla(),
          generation_options: [
            max_new_tokens: options.max_new_tokens,
            strategy: %{type: :greedy_search}
          ],
          compile: [batch_size: 1]
        )
      end,
      input: &NxAdapter.image_input/1,
      output: &NxAdapter.captions/1
    )
  end

  def adapter("clip.embedding", %{model: model}) do
    serving(
      {:clip, model},
      fn ->
        Models.clip_image_embedding(model,
          load_options: load(@clip, model),
          model_options: exla(),
          compile: [batch_size: 1]
        )
      end,
      input: &NxAdapter.image_input/1,
      output: &NxAdapter.embedding/1
    )
  end

  def adapter("text.embedding", %{model: model}) do
    serving(
      {:text_embedding, model},
      fn ->
        Models.text_embedding(model,
          load_options: load(@embedding, model),
          model_options: exla(),
          compile: [batch_size: 1, sequence_length: 256]
        )
      end,
      output: &NxAdapter.embedding/1
    )
  end

  defp serving(key, build, options),
    do: {AudioFlow.Graph.ModelAdapter, [key: key, build: build] ++ options}

  defp language_model(model, load_options, max_new_tokens) do
    Models.language_model(model,
      load_options: load_options,
      model_options: exla(),
      generation_options: [max_new_tokens: max_new_tokens, strategy: %{type: :greedy_search}]
    )
  end

  defp load(models, model) do
    case Map.get(models, model) do
      nil -> []
      revision -> [revision: revision]
    end
  end

  defp exla, do: [backend: EXLA.Backend]
end

defmodule AudioFlow.Graph.ModelAdapter do
  @moduledoc """
  Runs `AudioFlow.NxAdapter` on a shared serving from `AudioFlow.Servings`.

  Options: `:key` and `:build` for `AudioFlow.Servings.fetch/2`, and the
  `:input` and `:output` mappers of `AudioFlow.NxAdapter`.
  """
  @behaviour AudioFlow.Adapter

  @impl true
  def run(input, options, emit) do
    case AudioFlow.Servings.fetch(Keyword.fetch!(options, :key), Keyword.fetch!(options, :build)) do
      {:ok, name} ->
        AudioFlow.NxAdapter.run(
          input,
          [serving: name] ++ Keyword.take(options, [:input, :output]),
          emit
        )

      {:error, reason} ->
        {:error, {:model_load, reason}}
    end
  end
end
