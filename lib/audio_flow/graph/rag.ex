defmodule AudioFlow.Graph.Nodes.RAG do
  @moduledoc "Vector-to-document retrieval. Profiles are trusted application configuration."
  @behaviour AudioFlow.Graph.Node

  def nodes do
    [
      %{
        type: "rag.retrieve",
        title: "Retrieve documents",
        description: "Cosine search over pgvector embeddings; emits JSON documents.",
        input: :vector,
        output: :text,
        options: [
          %{
            name: :profile,
            type: :string,
            required: true,
            description: "Configured retrieval profile."
          },
          %{name: :limit, type: :integer, default: 5},
          %{name: :max_bytes, type: :integer, default: 32_768}
        ]
      }
    ]
  end

  def adapter("rag.retrieve", options) do
    profiles = Application.get_env(:audio_flow, :retrieval_profiles, %{})
    config = Map.fetch!(profiles, options.profile)

    {AudioFlow.RAG.Retrieve,
     Keyword.merge(config, limit: options.limit, max_bytes: options.max_bytes)}
  end
end
