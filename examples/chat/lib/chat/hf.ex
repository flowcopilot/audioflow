defmodule Chat.HF do
  @moduledoc """
  Downloads a pinned Hugging Face repository snapshot to a local directory.

  The EMLXAxon Qwen3 loader reads a checkpoint directory. This uses the
  `hf` CLI through `uvx`, so the only requirement is `uv`.
  """

  def snapshot!(repo, revision) do
    dir = Path.join([:filename.basedir(:user_cache, "audioflow_chat"), repo, revision])

    if not File.exists?(Path.join(dir, "config.json")) do
      uvx =
        System.find_executable("uvx") ||
          raise "Model downloads need uv: https://docs.astral.sh/uv/"

      {output, status} =
        System.cmd(
          uvx,
          [
            "--from",
            "huggingface_hub",
            "hf",
            "download",
            repo,
            "--revision",
            revision,
            "--local-dir",
            dir
          ],
          stderr_to_stdout: true
        )

      if status != 0, do: raise("Downloading #{repo} failed: #{output}")
    end

    dir
  end
end
