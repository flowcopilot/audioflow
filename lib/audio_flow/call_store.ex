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
  """
  @type store :: {module(), term()}
  @type call :: map()

  @callback create(term(), call()) :: {:ok, call()} | {:error, term()}
  @callback get(term(), String.t()) :: {:ok, call()} | {:error, :not_found}
  @doc "Writes `changes` if the call has `version` and `owner` holds its lease."
  @callback save(term(), String.t(), String.t(), non_neg_integer(), map()) ::
              {:ok, call()} | {:error, :stale}
  @doc "Takes up to `limit` active calls with expired or no leases."
  @callback claim(term(), String.t(), pos_integer(), pos_integer()) :: {:ok, [call()]}
  @doc "Extends the leases that `owner` still holds. Returns the renewed calls."
  @callback renew(term(), String.t(), [String.t()], pos_integer()) :: {:ok, [call()]}
  @doc "Ends a lease now, so another node can claim the call at once."
  @callback release(term(), String.t(), String.t()) :: :ok

  def create({module, config}, call), do: module.create(config, call)
  def get({module, config}, id), do: module.get(config, id)

  def save({module, config}, id, owner, version, changes),
    do: module.save(config, id, owner, version, changes)

  def claim({module, config}, owner, lease_ms, limit),
    do: module.claim(config, owner, lease_ms, limit)

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

  @doc "The current time in milliseconds since the epoch, as stores keep leases."
  def now, do: System.system_time(:millisecond)
end
