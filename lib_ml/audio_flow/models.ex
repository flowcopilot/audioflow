defmodule AudioFlow.Models do
  @moduledoc "Shared speech and language serving builders. Call once at application startup."

  def whisper(repository, options \\ []) do
    source = {:hf, repository}

    with {:ok, model} <- Bumblebee.load_model(source),
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
    source = {:hf, repository}

    with {:ok, model} <- Bumblebee.load_model(source),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer(source),
         {:ok, generation} <- Bumblebee.load_generation_config(source) do
      generation = Bumblebee.configure(generation, max_new_tokens: 128)

      {:ok,
       Bumblebee.Text.generation(
         model,
         tokenizer,
         generation,
         Keyword.merge([stream: true, defn_options: [compiler: EXLA]], options)
       )}
    end
  end

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
