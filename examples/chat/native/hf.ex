defmodule Chat.HF do
  @moduledoc """
  Downloads a pinned Hugging Face repository snapshot for the EMLXAxon loader.

  Uses hf_hub's configured cache (`config :hf_hub, :cache_dir, path`), returning
  its snapshot directory directly. Always checks the full repository listing:
  `config.json` alone does not prove a complete snapshot. Completed files are
  reused and interrupted file downloads are retried.
  """

  @spec snapshot!(String.t(), String.t()) :: Path.t()
  def snapshot!(repo, revision) do
    # In hf_hub 0.3.1 the documented per-call cache_dir is ignored; use the
    # application's cache configuration rather than changing global state here.
    case HfHub.Download.snapshot_download(
           repo_id: repo,
           revision: revision,
           cache_dir: HfHub.FS.cache_dir()
         ) do
      {:ok, dir} -> dir
      {:error, reason} -> raise "Downloading #{repo} at #{revision} failed: #{inspect(reason)}"
    end
  end
end
