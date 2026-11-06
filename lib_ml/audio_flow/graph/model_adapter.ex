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
