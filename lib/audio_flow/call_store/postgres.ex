defmodule AudioFlow.CallStore.Postgres do
  @moduledoc """
  PostgreSQL call store. Use `{AudioFlow.CallStore.Postgres, connection: conn}`
  with a Postgrex connection, and optionally `table:` (`"audio_flow_calls"`).
  Create the table with `schema_sql/1`; drop it with `DROP TABLE` to roll
  back.

  Claims use `FOR UPDATE SKIP LOCKED`, so nodes that claim at the same time
  get different calls. Lease times, and the times that calls compare across
  nodes, use the database clock.

  Only a save that matches no row (another version or owner) returns
  `{:error, :stale}`. Any other database error is returned as it is, so the
  caller can retry. A save sends only the fields in `changes`, and appends
  new history entries to the stored history.
  """
  @behaviour AudioFlow.CallStore

  @columns """
  id::text, room, agent, metadata::text, history::text, conversation_state, turns,
  pending_input::text, resume_token, status, lease_owner,
  (extract(epoch from lease_expires_at) * 1000)::bigint, version
  """

  @doc "SQL that creates the table and its claim index."
  def schema_sql(table \\ "audio_flow_calls") do
    table = identifier!(table)

    """
    CREATE TABLE IF NOT EXISTS #{table} (
      id uuid PRIMARY KEY,
      room text NOT NULL,
      agent text NOT NULL,
      metadata jsonb NOT NULL DEFAULT '{}',
      history jsonb NOT NULL DEFAULT '[]',
      conversation_state text,
      turns integer NOT NULL DEFAULT 0,
      pending_input jsonb,
      resume_token text,
      status text NOT NULL DEFAULT 'active',
      lease_owner text,
      lease_expires_at timestamptz,
      version bigint NOT NULL DEFAULT 0,
      updated_at timestamptz NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS #{table}_claim ON #{table} (lease_expires_at)
      WHERE status = 'active';
    """
  end

  @impl true
  def create(config, call) do
    call = AudioFlow.CallStore.new_call(call)

    query(
      config,
      """
      INSERT INTO #{table(config)} (id, room, agent, metadata)
      VALUES ($1::text::uuid, $2, $3, $4::text::jsonb)
      RETURNING #{@columns}
      """,
      [call.id, call.room, call.agent, JSON.encode!(call.metadata)]
    )
    |> one()
  end

  @impl true
  def get(config, id) do
    query(config, "SELECT #{@columns} FROM #{table(config)} WHERE id = $1::text::uuid", [id])
    |> one()
  end

  @impl true
  def save(config, id, owner, version, changes) do
    {sets, params} =
      changes
      |> Map.take([:history, :conversation_state, :turns, :pending_input, :resume_token, :status])
      |> Enum.with_index(4)
      |> Enum.map(fn {{key, value}, n} ->
        {assignment(key, value, n), encode(key, value)}
      end)
      |> Enum.unzip()

    sets = Enum.join(["version = version + 1", "updated_at = now()" | sets], ", ")

    query(
      config,
      """
      UPDATE #{table(config)} SET #{sets}
      WHERE id = $1::text::uuid AND version = $2 AND lease_owner = $3
      RETURNING #{@columns}
      """,
      [id, version, owner | params]
    )
    |> one()
    |> case do
      {:error, :not_found} -> {:error, :stale}
      result -> result
    end
  end

  @impl true
  def claim(config, owner, lease_ms, limit, exclude) do
    table = table(config)

    query(
      config,
      """
      UPDATE #{table} SET lease_owner = $1,
        lease_expires_at = now() + $2 * interval '1 millisecond',
        version = version + 1, updated_at = now()
      WHERE id IN (
        SELECT id FROM #{table}
        WHERE status = 'active' AND (lease_expires_at IS NULL OR lease_expires_at <= now())
          AND NOT (id = ANY($4::text[]::uuid[]))
        ORDER BY lease_expires_at NULLS FIRST
        LIMIT $3
        FOR UPDATE SKIP LOCKED
      )
      RETURNING #{@columns}
      """,
      [owner, lease_ms, limit, exclude]
    )
    |> all()
  end

  @impl true
  def renew(config, owner, ids, lease_ms) do
    query(
      config,
      """
      UPDATE #{table(config)} SET lease_expires_at = now() + $3 * interval '1 millisecond'
      WHERE id = ANY($2::text[]::uuid[]) AND lease_owner = $1 AND status = 'active'
      RETURNING id::text
      """,
      [owner, ids, lease_ms]
    )
    |> case do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [id] -> id end)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def release(config, id, owner) do
    case query(
           config,
           """
           UPDATE #{table(config)} SET lease_expires_at = now()
           WHERE id = $1::text::uuid AND lease_owner = $2
           """,
           [id, owner]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def now(config) do
    case query(config, "SELECT (extract(epoch from clock_timestamp()) * 1000)::bigint", []) do
      {:ok, %{rows: [[now]]}} -> {:ok, now}
      {:error, reason} -> {:error, reason}
    end
  end

  # Appends to the stored history. The version check in the WHERE clause makes
  # it the history that the writer saw.
  defp assignment(:history, {:append, _}, n), do: "history = history || $#{n}::text::jsonb"
  defp assignment(key, _value, n), do: "#{key} = #{placeholder(key, n)}"

  defp placeholder(key, n) when key in [:history, :pending_input], do: "$#{n}::text::jsonb"
  defp placeholder(_key, n), do: "$#{n}"

  defp encode(:history, {:append, turns}), do: encode(:history, turns)
  defp encode(:history, turns), do: JSON.encode!(Enum.map(turns, fn {u, a} -> [u, a] end))
  defp encode(:pending_input, nil), do: nil
  defp encode(:pending_input, input), do: JSON.encode!(input)
  defp encode(:status, status), do: Atom.to_string(status)
  defp encode(:conversation_state, nil), do: nil
  defp encode(:conversation_state, state), do: to_string(state)
  defp encode(_key, value), do: value

  defp query(config, sql, params) do
    Postgrex.query(Keyword.fetch!(config, :connection), sql, params,
      timeout: Keyword.get(config, :timeout_ms, 5_000)
    )
  end

  defp one({:ok, %{rows: [row]}}), do: {:ok, decode(row)}
  defp one({:ok, %{rows: []}}), do: {:error, :not_found}
  defp one({:error, reason}), do: {:error, reason}

  defp all({:ok, %{rows: rows}}), do: {:ok, Enum.map(rows, &decode/1)}
  defp all({:error, reason}), do: {:error, reason}

  defp decode([
         id,
         room,
         agent,
         metadata,
         history,
         state,
         turns,
         pending,
         token,
         status,
         owner,
         expires,
         version
       ]) do
    %{
      id: id,
      room: room,
      agent: agent,
      metadata: JSON.decode!(metadata),
      history: Enum.map(JSON.decode!(history), fn [u, a] -> {u, a} end),
      conversation_state: state,
      turns: turns,
      pending_input: pending && JSON.decode!(pending),
      resume_token: token,
      status: String.to_existing_atom(status),
      lease_owner: owner,
      lease_expires_at: expires,
      version: version
    }
  end

  defp table(config), do: identifier!(Keyword.get(config, :table, "audio_flow_calls"))

  defp identifier!(name) do
    if Regex.match?(~r/\A[a-z_][a-z0-9_]{0,62}\z/, name),
      do: name,
      else: raise(ArgumentError, "invalid table name #{inspect(name)}")
  end
end
