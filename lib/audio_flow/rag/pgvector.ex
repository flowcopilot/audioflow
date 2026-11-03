defmodule AudioFlow.RAG.Backend do
  @moduledoc "Retrieval backend contract. Results contain id, content, metadata, and distance."
  @callback retrieve([number()], keyword()) :: {:ok, [map()]} | {:error, term()}
end

defmodule AudioFlow.RAG.Pgvector do
  @moduledoc "Parameterized cosine retrieval over the audio_flow_documents schema."
  @behaviour AudioFlow.RAG.Backend

  @sql """
  SELECT id::text, content, metadata, embedding <=> $1::text::vector AS distance
  FROM audio_flow_documents
  WHERE collection = $2 AND embedding <=> $1::text::vector <= $4
  ORDER BY embedding <=> $1::text::vector
  LIMIT $3
  """

  @impl true
  def retrieve(vector, options) do
    query = Keyword.get(options, :query, &Postgrex.query/4)

    params = [
      JSON.encode!(vector),
      Keyword.fetch!(options, :collection),
      Keyword.fetch!(options, :limit),
      Keyword.fetch!(options, :max_distance)
    ]

    case query.(Keyword.fetch!(options, :connection), @sql, params,
           timeout: Keyword.get(options, :timeout_ms, 5_000)
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [id, content, metadata, distance] ->
           %{id: id, content: content, metadata: metadata, distance: distance}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule AudioFlow.RAG.Retrieve do
  @moduledoc "Retrieves documents from a configured backend; never substitutes generated results."
  @behaviour AudioFlow.Adapter

  @impl true
  def run(vector, options, emit) do
    dimensions = Keyword.fetch!(options, :dimensions)
    limit = Keyword.get(options, :limit, 5)
    distance = Keyword.get(options, :max_distance, 2.0)
    max_bytes = Keyword.get(options, :max_bytes, 32_768)

    cond do
      not (is_list(vector) and length(vector) == dimensions and
             Enum.all?(vector, &is_number/1) and Enum.any?(vector, &(&1 != 0))) ->
        {:error, :invalid_embedding}

      not (is_integer(limit) and limit in 1..100 and is_number(distance) and
             distance >= 0 and distance <= 2 and is_integer(max_bytes) and max_bytes > 0) ->
        {:error, :invalid_retrieval_limits}

      true ->
        {backend, backend_options} = Keyword.fetch!(options, :backend)

        with {:ok, documents} <-
               backend.retrieve(
                 vector,
                 Keyword.merge(backend_options, limit: limit, max_distance: distance)
               ) do
          text = JSON.encode!(documents)
          if byte_size(text) <= max_bytes, do: emit.(text), else: {:error, :retrieval_too_large}
        end
    end
  end
end
