defmodule AudioFlow.Models do
  @moduledoc "Shared native model serving builders. Call once at application startup."

  def whisper(repository, options \\ []) do
    {load_options, options} = Keyword.pop(options, :load_options, [])
    {model_options, options} = Keyword.pop(options, :model_options, [])
    source = source(repository, load_options)

    with {:ok, model} <- Bumblebee.load_model(source, model_options),
         {:ok, featurizer} <- Bumblebee.load_featurizer(source),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer(source),
         {:ok, generation} <- Bumblebee.load_generation_config(source) do
      {:ok,
       Bumblebee.Audio.speech_to_text_whisper(
         model,
         featurizer,
         tokenizer,
         generation,
         Keyword.merge([defn_options: [compiler: EXLA]], options)
       )}
    end
  end

  def language_model(repository, options \\ []) do
    {load_options, options} = Keyword.pop(options, :load_options, [])
    {model_options, options} = Keyword.pop(options, :model_options, [])
    {generation_options, options} = Keyword.pop(options, :generation_options, [])
    source = source(repository, load_options)

    with {:ok, model} <- Bumblebee.load_model(source, model_options),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer(source),
         {:ok, generation} <- Bumblebee.load_generation_config(source) do
      generation =
        Bumblebee.configure(generation, Keyword.merge([max_new_tokens: 128], generation_options))

      {:ok,
       Bumblebee.Text.generation(
         model,
         tokenizer,
         generation,
         Keyword.merge([stream: true, defn_options: [compiler: EXLA]], options)
       )}
    end
  end

  @doc """
  Build a text embedding serving, with masked mean pooling and L2 normalization.

  Defaults match mean-pooled BERT sentence models such as all-MiniLM-L6-v2.
  Set serving options for other pooling rules and add model-specific text
  prefixes in the adapter's input mapper when required.
  """
  def text_embedding(repository, options \\ []) do
    {load_options, options} = Keyword.pop(options, :load_options, [])
    {model_options, options} = Keyword.pop(options, :model_options, [])
    source = source(repository, load_options)

    with {:ok, model} <- Bumblebee.load_model(source, model_options),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer(source) do
      {:ok,
       Bumblebee.Text.text_embedding(
         model,
         tokenizer,
         Keyword.merge(
           [
             output_attribute: :hidden_state,
             output_pool: :mean_pooling,
             embedding_processor: :l2_norm,
             defn_options: [compiler: EXLA]
           ],
           options
         )
       )}
    end
  end

  @doc "Build normalized, projected CLIP image embeddings in the joint text-image space."
  def clip_image_embedding(repository, options \\ []) do
    {load_options, options} = Keyword.pop(options, :load_options, [])
    {model_options, options} = Keyword.pop(options, :model_options, [])
    source = source(repository, load_options)

    model_options =
      Keyword.merge(
        [module: Bumblebee.Vision.ClipVision, architecture: :for_embedding],
        model_options
      )

    with {:ok, model} <- Bumblebee.load_model(source, model_options),
         {:ok, featurizer} <- Bumblebee.load_featurizer(source) do
      {:ok,
       Bumblebee.Vision.image_embedding(
         model,
         featurizer,
         Keyword.merge(
           [
             output_attribute: :embedding,
             embedding_processor: :l2_norm,
             defn_options: [compiler: EXLA]
           ],
           options
         )
       )}
    end
  end

  @doc "Build a shared image caption serving for a supported model such as BLIP."
  def image_captioning(repository, options \\ []) do
    {load_options, options} = Keyword.pop(options, :load_options, [])
    {model_options, options} = Keyword.pop(options, :model_options, [])
    {generation_options, options} = Keyword.pop(options, :generation_options, [])
    source = source(repository, load_options)

    with {:ok, model} <- Bumblebee.load_model(source, model_options),
         {:ok, featurizer} <- Bumblebee.load_featurizer(source),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer(source),
         {:ok, generation} <- Bumblebee.load_generation_config(source) do
      generation =
        Bumblebee.configure(generation, Keyword.merge([max_new_tokens: 32], generation_options))

      {:ok,
       Bumblebee.Vision.image_to_text(
         model,
         featurizer,
         tokenizer,
         generation,
         Keyword.merge([defn_options: [compiler: EXLA]], options)
       )}
    end
  end

  defp source(repository, options) when is_binary(repository), do: {:hf, repository, options}
  defp source({:hf, repository}, options), do: {:hf, repository, options}

  defp source({:hf, repository, existing}, options),
    do: {:hf, repository, Keyword.merge(existing, options)}

  defp source({:local, _} = repository, []), do: repository

  @doc "Build a shared Transmuter VITS or SpeechT5 speech serving."
  def text_to_speech(repository, options \\ []) do
    Transmuter.Audio.text_to_speech(
      {:hf, repository},
      Keyword.merge([defn_options: [compiler: EXLA]], options)
    )
  end

  @doc "A supervised serving with explicit queue delay and batch size."
  def child_spec(name, serving, options \\ []) do
    Supervisor.child_spec(
      {Nx.Serving,
       Keyword.merge(
         [name: name, serving: serving, batch_size: 1, batch_timeout: 5],
         options
       )},
      id: name
    )
  end
end
