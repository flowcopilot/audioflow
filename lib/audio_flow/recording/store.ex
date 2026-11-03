defmodule AudioFlow.Recording.Store do
  @moduledoc """
  Private local JSON turn store with finite age, count and artifact byte limits.
  Use a dedicated directory controlled by the application OS user. Symlink
  paths are rejected; this is not a sandbox against concurrent filesystem edits
  by that same user. Deletion unlinks artifacts, not backups or secure erasure.
  """
  @enforce_keys [:root]
  defstruct [:root, max_age_ms: 86_400_000, max_records: 1000, max_bytes: 8_000_000]
  @name ~r/\A([0-9]+)-[a-f0-9]{32}\.json\z/

  def new(root, options \\ []) do
    store = struct!(__MODULE__, Keyword.merge(options, root: Path.expand(root)))

    for key <- [:max_age_ms, :max_records, :max_bytes] do
      unless is_integer(Map.fetch!(store, key)) and Map.fetch!(store, key) > 0,
        do: raise(ArgumentError, "#{key} must be positive")
    end

    with :ok <- safe_directory(store.root),
         :ok <- File.mkdir_p(store.root),
         :ok <- File.chmod(store.root, 0o700),
         {:ok, _} <- cleanup(store) do
      {:ok, store}
    end
  end

  def write(store, record) do
    data = JSON.encode!(record)

    if byte_size(data) > store.max_bytes,
      do: {:error, :record_too_large},
      else: write_file(store, data)
  end

  defp write_file(store, data) do
    id =
      "#{System.system_time(:millisecond)}-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}.json"

    temporary = Path.join(store.root, ".#{id}.tmp")

    with :ok <- safe_directory(store.root),
         {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]) do
      result = persist(store, file, temporary, id, data)
      File.close(file)
      File.rm(temporary)
      result
    end
  end

  defp persist(store, file, temporary, id, data) do
    with :ok <- File.chmod(temporary, 0o600),
         :ok <- IO.binwrite(file, data),
         :ok <- :file.sync(file),
         :ok <- File.close(file),
         :ok <- File.rename(temporary, Path.join(store.root, id)),
         {:ok, _} <- cleanup(store) do
      {:ok, id}
    end
  end

  def list(store) do
    with {:ok, _} <- cleanup(store), {:ok, entries} <- entries(store) do
      {:ok, Enum.map(entries, &elem(&1, 0))}
    end
  end

  def read(store, id) do
    with :ok <- valid_id(id),
         {:ok, ids} <- list(store),
         true <- id in ids,
         {:ok, stat} <- File.lstat(Path.join(store.root, id)),
         true <- stat.type == :regular and stat.size <= store.max_bytes,
         {:ok, data} <- File.read(Path.join(store.root, id)) do
      JSON.decode(data)
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def delete(store, id) do
    with :ok <- valid_id(id),
         :ok <- safe_directory(store.root),
         {:ok, stat} <- File.lstat(Path.join(store.root, id)),
         true <- stat.type == :regular do
      File.rm(Path.join(store.root, id))
    else
      false -> {:error, :unsafe_path}
      error -> error
    end
  end

  @doc "Enforce retention; run periodically when no writes or reads occur. Returns removed IDs."
  def cleanup(store) do
    with :ok <- safe_directory(store.root),
         :ok <- cleanup_temporary(store),
         {:ok, entries} <- entries(store) do
      cutoff = System.system_time(:millisecond) - store.max_age_ms
      {expired, live} = Enum.split_with(entries, fn {_, time} -> time <= cutoff end)
      excess = Enum.take(live, max(0, length(live) - store.max_records))

      Enum.reduce_while(expired ++ excess, {:ok, []}, fn {id, _}, {:ok, removed} ->
        remove_record(store, id, removed)
      end)
    end
  end

  defp remove_record(store, id, removed) do
    case delete(store, id) do
      :ok -> {:cont, {:ok, [id | removed]}}
      {:error, :enoent} -> {:cont, {:ok, removed}}
      error -> {:halt, error}
    end
  end

  # A killed writer can leave sanitized temporary data. Expire it too, but do
  # not touch recent temporary files that may still belong to a live writer.
  defp cleanup_temporary(store) do
    cutoff = System.system_time(:millisecond) - store.max_age_ms

    with {:ok, names} <- File.ls(store.root) do
      Enum.reduce_while(names, :ok, fn name, :ok -> remove_temporary(store, name, cutoff) end)
    end
  end

  defp remove_temporary(store, name, cutoff) do
    case Regex.run(~r/\A\.([0-9]+)-[a-f0-9]{32}\.json\.tmp\z/, name) do
      [_, timestamp] ->
        path = Path.join(store.root, name)

        if String.to_integer(timestamp) <= cutoff and
             match?({:ok, %{type: :regular}}, File.lstat(path)),
           do: remove_temporary_file(path),
           else: {:cont, :ok}

      _ ->
        {:cont, :ok}
    end
  end

  defp remove_temporary_file(path) do
    case File.rm(path) do
      :ok -> {:cont, :ok}
      {:error, :enoent} -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp entries(store) do
    with {:ok, names} <- File.ls(store.root) do
      entries =
        for name <- names,
            [_, timestamp] <- [Regex.run(@name, name)],
            {:ok, %{type: :regular}} <- [File.lstat(Path.join(store.root, name))],
            do: {name, String.to_integer(timestamp)}

      {:ok, Enum.sort_by(entries, fn {id, time} -> {time, id} end)}
    end
  end

  defp valid_id(id) when is_binary(id) do
    if Regex.match?(@name, id), do: :ok, else: {:error, :invalid_id}
  end

  defp valid_id(_), do: {:error, :invalid_id}

  defp safe_directory(path) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while(:ok, fn part, :ok ->
      case File.lstat(part) do
        {:ok, %{type: :directory}} -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, :unsafe_path}}
        error -> {:halt, error}
      end
    end)
  end
end
