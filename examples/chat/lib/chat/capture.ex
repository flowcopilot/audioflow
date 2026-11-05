defmodule Chat.Capture do
  @moduledoc "Per-tab opt-in text-only recordings. All text is redacted; PCM is never stored."
  alias AudioFlow.Recording
  alias AudioFlow.Recording.Store

  def open(session) do
    root =
      Path.join(
        System.tmp_dir!(),
        "audioflow-chat-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"
      )

    with {:ok, store} <-
           Store.new(root, max_age_ms: 3_600_000, max_records: 20, max_bytes: 262_144) do
      {:ok,
       Recording.new(session, store,
         redactor: fn _ -> {:ok, "[REDACTED]"} end,
         max_bytes: 131_072,
         max_events: 1024
       )}
    end
  end

  def list(nil), do: []

  def list(recorder) do
    case Store.list(recorder.store) do
      {:ok, ids} -> ids
      _ -> []
    end
  end

  def close(nil), do: :ok

  def close(recorder) do
    Recording.discard(recorder)
    File.rm_rf(recorder.store.root)
    :ok
  end
end
