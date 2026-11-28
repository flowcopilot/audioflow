defmodule AudioFlow.CallStore do
  @moduledoc """
  Storage for durable calls. A store is a `{module, config}` tuple.

  A call is a map with `:id`, `:room`, `:agent` (module name), `:metadata`,
  `:history` (`{user, assistant}` pairs), `:conversation_state`, `:turns`,
  `:pending_input`, `:resume_token`, `:status` (`:active` or `:ended`),
  `:lease_owner`, `:lease_expires_at` (milliseconds since the epoch) and
  `:version`.

  Leases fence writes. An owner renews its leases; any node can claim an
  active call whose lease expired. Every write names the version it read, so
  an owner that lost its lease (for example, after a network split) cannot
  overwrite a newer snapshot: the write returns `{:error, :stale}`.

  `:stale` means only that: the version or the lease owner did not match.
  Any other failure (a database that is down, a timeout) is `{:error, reason}`
  with another reason, so the caller can retry and keep its lease.

  In the changes of `save/5`, `:history` is the whole list, or
  `{:append, entries}` to add `entries` to the stored history. The version
  check makes the stored history the one the writer last saw, so a store can
  append without writing the whole list again.
  """
  @type store :: {module(), term()}
  @type call :: map()

  @callback create(term(), call()) :: {:ok, call()} | {:error, term()}
  @callback get(term(), String.t()) :: {:ok, call()} | {:error, :not_found | term()}
  @doc "Writes `changes` if the call has `version` and `owner` holds its lease."
  @callback save(term(), String.t(), String.t(), non_neg_integer(), map()) ::
              {:ok, call()} | {:error, :stale | term()}
  @doc """
  Takes up to `limit` active calls with expired or no leases, except the
  calls in `exclude` (the IDs that run on the claiming node).
  """
  @callback claim(term(), String.t(), pos_integer(), pos_integer(), [String.t()]) ::
              {:ok, [call()]} | {:error, term()}
  @doc "Extends the leases that `owner` still holds. Returns the IDs of the renewed calls."
  @callback renew(term(), String.t(), [String.t()], pos_integer()) ::
              {:ok, [String.t()]} | {:error, term()}
  @doc "Ends a lease now, so another node can claim the call at once."
  @callback release(term(), String.t(), String.t()) :: :ok | {:error, term()}
  @doc """
  The current time in milliseconds on the clock that sets the leases. Stores
  with a shared clock (a database) return it, so timestamps that nodes
  compare do not depend on the clock of one node.
  """
  @callback now(term()) :: {:ok, integer()} | {:error, term()}
  @optional_callbacks now: 1

  def create({module, config}, call), do: module.create(config, call)
  def get({module, config}, id), do: module.get(config, id)

  def save({module, config}, id, owner, version, changes),
    do: module.save(config, id, owner, version, changes)

  def claim({module, config}, owner, lease_ms, limit, exclude \\ []),
    do: module.claim(config, owner, lease_ms, limit, exclude)

  def renew({module, config}, owner, ids, lease_ms),
    do: module.renew(config, owner, ids, lease_ms)

  def release({module, config}, id, owner), do: module.release(config, id, owner)

  @doc "A new active call record with defaults for the fields not in `attrs`."
  def new_call(attrs) do
    Map.merge(
      %{
        id: uuid(),
        metadata: %{},
        history: [],
        conversation_state: nil,
        turns: 0,
        pending_input: nil,
        resume_token: nil,
        status: :active,
        lease_owner: nil,
        lease_expires_at: nil,
        version: 0
      },
      attrs
    )
  end

  @doc "A random (version 4) UUID string for a call ID."
  def uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = <<a::48, 4::4, b::12, 2::2, c::62>>

    [<<u0::32>>, <<u1::16>>, <<u2::16>>, <<u3::16>>, <<u4::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  @doc "The time of this node in milliseconds since the epoch."
  def now, do: System.system_time(:millisecond)

  @doc """
  The time on the clock of `store` (see the `now/1` callback). Falls back to
  the clock of this node for a store without a shared clock, or when it
  fails.
  """
  def now({module, config}) do
    with true <- Code.ensure_loaded?(module) and function_exported?(module, :now, 1),
         {:ok, now} <- module.now(config) do
      now
    else
      _ -> now()
    end
  end
end
