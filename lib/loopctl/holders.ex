defmodule Loopctl.Holders do
  @moduledoc """
  Session holders and their credentials (US-52.13, Epic 52 release 3).

  A holder is one session of an agent: an interactive Claude Code session, a runner session
  (US-52.15) or a cloud session. It registers once, gets a credential of its own (an `:agent`
  `api_keys` row carrying its `holder_id`), keeps a lease alive by heartbeating, and ends.
  Before this, every fleet session authenticated with one shared agent key and loopctl could
  not tell two of them apart (loopctl#707).

  ## Where the state lives

  The holder is a `holders` row and its credential an `api_keys` row; both are written on
  `AdminRepo` with an explicit `tenant_id` predicate on every read, because the credential
  write has to commit with the holder write and `api_keys` is AdminRepo's table. The raw key
  exists only in the register response.

  ## Retries

  A register is keyed by `(tenant, agent, session_id)`. A transaction-scoped advisory lock on
  that triple serialises two registers of one session, and `holders_live_session_uidx` is the
  backstop, so a retried register finds the live holder and ROTATES its credential (the caller
  never saw the earlier one) instead of creating a second holder. `api_keys_one_live_key_per_holder_idx`
  holds the holder to one live credential. A repeated end finds the holder ended and writes
  nothing.

  ## Cache invalidation happens after commit

  `Loopctl.Auth.ApiKeyCache` is read-through: a request that misses while a revoke is still
  uncommitted reloads the still-live row and caches it under the generation the revoke
  already bumped. So every key hash this module revokes or re-dates is invalidated again
  AFTER its transaction commits, which is the moment the database stops answering with the
  old row.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Holders.Holder

  @default_lease_seconds 300
  @default_heartbeat_seconds 60
  @self_kinds [:interactive, :cloud]

  @type register_result :: %{
          holder: Holder.t(),
          raw_key: String.t(),
          api_key: ApiKey.t(),
          outcome: :created | :rotated
        }

  @doc """
  How long a holder's lease runs from its last heartbeat: `:holder_lease_seconds`, set from
  `HOLDER_LEASE_SECONDS`, default #{@default_lease_seconds}. US-52.19 measures and sets it.
  """
  @spec lease_seconds() :: pos_integer()
  def lease_seconds do
    case Application.get_env(:loopctl, :holder_lease_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_lease_seconds
    end
  end

  @doc """
  How often a holder heartbeats: `:holder_heartbeat_seconds`, set from
  `HOLDER_HEARTBEAT_SECONDS`, default #{@default_heartbeat_seconds}.
  """
  @spec heartbeat_seconds() :: pos_integer()
  def heartbeat_seconds do
    case Application.get_env(:loopctl, :holder_heartbeat_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_heartbeat_seconds
    end
  end

  @doc """
  How long a holder credential lives past the moment its lease is set: the lease plus one
  heartbeat interval, so a credential never expires before the lease it carries, and a missed
  heartbeat costs the session one interval rather than its key.
  """
  @spec credential_ttl_seconds() :: pos_integer()
  def credential_ttl_seconds, do: lease_seconds() + heartbeat_seconds()

  @doc "A holder of `tenant_id` by id."
  @spec get_holder(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Holder.t()} | {:error, :not_found}
  def get_holder(tenant_id, holder_id) when is_binary(tenant_id) and is_binary(holder_id) do
    case Ecto.UUID.cast(holder_id) do
      {:ok, id} ->
        case AdminRepo.one(from(h in Holder, where: h.tenant_id == ^tenant_id and h.id == ^id)) do
          nil -> {:error, :not_found}
          holder -> {:ok, holder}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Registers a session as a holder of `agent_id` and mints its credential.

  `attrs` carries the session's own description: `kind`, `session_id`, `host` and `worktree`.
  A live holder for the same `(agent_id, session_id)` is reused, its lease reset and its
  credential rotated (`outcome: :rotated`); otherwise a new holder is created
  (`outcome: :created`). Either way the result carries the new raw key once.

  ## Options

    * `:now` — the instant the lease is measured from (default `DateTime.utc_now/0`).
    * `:kinds` — the kinds a caller may register as (default `[:interactive, :cloud]`).
    * `:actor_type`, `:actor_id`, `:actor_label`, `:metadata` — the audit actor
      (`LoopctlWeb.AuditContext.from_conn/1`).
  """
  @spec register(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, register_result()} | {:error, Ecto.Changeset.t() | term()}
  def register(tenant_id, agent_id, attrs, opts \\ [])
      when is_binary(tenant_id) and is_binary(agent_id) and is_map(attrs) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    # A runner session is a holder through placement (US-52.15), which binds its dispatch; a
    # session describing itself as one would claim a binding it does not have.
    changeset =
      %Holder{tenant_id: tenant_id, agent_id: agent_id}
      |> Holder.registration_changeset(attrs)
      |> Ecto.Changeset.validate_inclusion(:kind, Keyword.get(opts, :kinds, @self_kinds),
        message: "a session registers as interactive or cloud; runner sessions are placed"
      )

    if changeset.valid? do
      AdminRepo.transaction(fn -> register_session(changeset, now, opts) end)
      |> after_commit()
    else
      {:error, changeset}
    end
  end

  defp register_session(changeset, now, opts) do
    tenant_id = Ecto.Changeset.get_field(changeset, :tenant_id)
    agent_id = Ecto.Changeset.get_field(changeset, :agent_id)
    session_id = Ecto.Changeset.get_field(changeset, :session_id)

    lock_session(tenant_id, agent_id, session_id)

    case live_holder(tenant_id, agent_id, session_id) do
      nil -> create_holder(changeset, now, opts)
      %Holder{} = holder -> rotate_holder(holder, now, opts)
    end
  end

  @doc """
  Renews the lease of the holder `holder_id`, by its own credential `caller`.

  Sets `last_seen_at` to now and `lease_until` to now plus `lease_seconds/0`, and moves the
  credential's `expires_at` to the new lease plus one heartbeat interval. A holder that is not
  `caller`'s is `:not_found` (no existence oracle); an ended one is `:holder_ended`.
  """
  @spec heartbeat(Ecto.UUID.t(), ApiKey.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Holder.t()} | {:error, :not_found | :holder_ended}
  def heartbeat(tenant_id, %ApiKey{} = caller, holder_id, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    AdminRepo.transaction(fn ->
      with {:ok, holder} <- owned_holder_for_update(tenant_id, caller, holder_id),
           :ok <- refuse_ended(holder) do
        lease_until = DateTime.add(now, lease_seconds(), :second)

        holder =
          holder
          |> Ecto.Changeset.change(last_seen_at: now, lease_until: lease_until)
          |> AdminRepo.update!()

        hashes =
          redate_credentials(
            tenant_id,
            holder.id,
            DateTime.add(lease_until, heartbeat_seconds(), :second)
          )

        {holder, hashes}
      else
        {:error, reason} -> AdminRepo.rollback(reason)
      end
    end)
    |> after_commit()
  end

  @doc """
  Ends the holder `holder_id`, by its own credential `caller`: sets `ended_at` and revokes its
  credential, in one transaction. A repeated end returns the ended holder and writes nothing.
  """
  @spec end_holder(Ecto.UUID.t(), ApiKey.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Holder.t()} | {:error, :not_found}
  def end_holder(tenant_id, %ApiKey{} = caller, holder_id, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    AdminRepo.transaction(fn ->
      case owned_holder_for_update(tenant_id, caller, holder_id) do
        {:ok, %Holder{ended_at: %DateTime{}} = holder} ->
          {holder, []}

        {:ok, holder} ->
          end_live_holder(holder, :ended, now, opts)

        {:error, reason} ->
          AdminRepo.rollback(reason)
      end
    end)
    |> after_commit()
  end

  # --- runner sessions (US-52.15) ---

  @doc """
  Creates the holder of a runner session as part of minting its dispatch: kind
  `:runner_session`, the runner's agent, `host` = the runner row's name (the one host loopctl
  attests rather than takes from the session), `dispatch_id`, the placeholder session id
  `"dispatch:<dispatch_id>"` until the runner's accept names the real one, and `lease_until`
  the dispatch's cap.

  Runs inside the caller's `AdminRepo` transaction (`Loopctl.Dispatches.create_dispatch/3`'s
  Multi), so a mint that fails leaves no holder row. No session ever calls this: a session
  cannot register as `:runner_session` (`register/4` refuses the kind).
  """
  @spec insert_runner_session(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Holder.t()} | {:error, Ecto.Changeset.t()}
  def insert_runner_session(tenant_id, attrs, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    %Holder{
      tenant_id: tenant_id,
      agent_id: Map.fetch!(attrs, :agent_id),
      dispatch_id: Map.fetch!(attrs, :dispatch_id),
      runner_dispatch_id: Map.fetch!(attrs, :runner_dispatch_id),
      kind: :runner_session,
      last_seen_at: now,
      lease_until: Map.fetch!(attrs, :lease_until)
    }
    |> Ecto.Changeset.change(
      session_id: "dispatch:#{Map.fetch!(attrs, :dispatch_id)}",
      host: Map.fetch!(attrs, :host)
    )
    |> Ecto.Changeset.validate_required([:session_id, :host])
    |> Ecto.Changeset.validate_length(:host, min: 1, max: 255)
    |> AdminRepo.insert()
    |> case do
      {:ok, holder} ->
        audit!(holder, "registered", %{"dispatch_id" => holder.dispatch_id}, opts)
        {:ok, holder}

      error ->
        error
    end
  end

  @doc """
  The holder a dispatch's session is, or `nil`: a dispatch minted before US-52.15, or by any
  path other than a runner placement, has none. Tenant-scoped on `AdminRepo`.
  """
  @spec holder_for_dispatch(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: Holder.t() | nil
  def holder_for_dispatch(_tenant_id, nil), do: nil

  def holder_for_dispatch(tenant_id, dispatch_id) do
    from(h in Holder,
      where: h.tenant_id == ^tenant_id and h.dispatch_id == ^dispatch_id,
      order_by: [desc: h.inserted_at],
      limit: 1
    )
    |> AdminRepo.one()
  end

  @doc """
  Records what a runner's accept says about the session it is about to start (contract
  1.35.0): its `session_id` and `worktree`, and the moment it was seen. Writes only a LIVE
  holder, so an accept resent after the session ended changes nothing; a resent accept with
  the same values writes the same values. An accept that names neither still moves
  `last_seen_at`. `:ok` when the dispatch has no live holder.

  Keyed by the WIRE dispatch id the accept names (`runner_dispatch_id`), never by the
  session's `dispatches` row.
  """
  @spec record_runner_accept(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) :: :ok
  def record_runner_accept(tenant_id, runner_dispatch_id, fields, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    set =
      [last_seen_at: now, updated_at: now] ++
        for {key, value} <- [session_id: fields[:session_id], worktree: fields[:worktree]],
            is_binary(value),
            do: {key, value}

    live =
      from(h in Holder,
        where:
          h.tenant_id == ^tenant_id and h.runner_dispatch_id == ^runner_dispatch_id and
            is_nil(h.ended_at)
      )

    # Its own transaction, so a conflict rolls back only this write (a savepoint inside a
    # caller's transaction) and the fallback below can still run.
    try do
      AdminRepo.transaction(fn -> AdminRepo.update_all(live, set: set) end)
    rescue
      # Another live holder of the runner's agent already holds that session id
      # (`holders_live_session_uidx`): the runner named an id that is not this session's. Keep
      # the placeholder, record the sighting, and never crash the runner's channel over it.
      e in Postgrex.Error ->
        if e.postgres[:code] != :unique_violation, do: reraise(e, __STACKTRACE__)

        Logger.warning(
          "runner accept for dispatch #{runner_dispatch_id} named a session id another live holder " <>
            "holds; kept the placeholder"
        )

        AdminRepo.update_all(live, set: [last_seen_at: now, updated_at: now])
    end

    :ok
  end

  @doc """
  Ends the holder of a runner session whose session ended (`session_ended`): `ended_at` set,
  its credential revoked, one `ended` audit row. A holder already ended, or a dispatch with no
  holder, changes nothing, so a replayed report writes nothing twice. Keyed by the wire
  dispatch id `session_ended` names (`runner_dispatch_id`).
  """
  @spec end_runner_session(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Holder.t() | nil} | {:error, term()}
  def end_runner_session(tenant_id, runner_dispatch_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    AdminRepo.transaction(fn ->
      from(h in Holder,
        where:
          h.tenant_id == ^tenant_id and h.runner_dispatch_id == ^runner_dispatch_id and
            is_nil(h.ended_at),
        lock: "FOR UPDATE"
      )
      |> AdminRepo.all()
      |> Enum.reduce({nil, []}, fn holder, {_last, hashes} ->
        {ended, more} = end_live_holder(holder, :ended, now, opts)
        {ended, hashes ++ more}
      end)
    end)
    |> after_commit()
  end

  @doc """
  Ends, inside the caller's transaction, every live holder of `dispatch_ids` in `tenant_id`:
  the undo of a placement and every other revoke of a session dispatch
  (`Loopctl.Dispatches.revoke/3`), and a dispatch's expiry (`reason: :lapsed`). The
  dispatches' keys are the holders' credentials, and the revoke that calls this revokes them,
  so this writes the holder rows only. Returns how many it ended.
  """
  @spec end_for_dispatches(Ecto.UUID.t(), [Ecto.UUID.t()], DateTime.t(), :ended | :lapsed) ::
          non_neg_integer()
  def end_for_dispatches(_tenant_id, [], _now, _reason), do: 0

  def end_for_dispatches(tenant_id, dispatch_ids, now, reason) do
    {count, _} =
      from(h in Holder,
        where: h.tenant_id == ^tenant_id and h.dispatch_id in ^dispatch_ids and is_nil(h.ended_at)
      )
      |> AdminRepo.update_all(set: [ended_at: now, ended_reason: reason, updated_at: now])

    count
  end

  # --- register ---

  # One register of one session at a time. hashtextextended is 64-bit, so two different
  # sessions sharing a lock is a 2^-64 event that costs only a short wait.
  defp lock_session(tenant_id, agent_id, session_id) do
    AdminRepo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "holder_register:#{tenant_id}:#{agent_id}:#{session_id}"
    ])
  end

  defp live_holder(tenant_id, agent_id, session_id) do
    from(h in Holder,
      where: h.tenant_id == ^tenant_id,
      where: h.agent_id == ^agent_id,
      where: h.session_id == ^session_id,
      where: is_nil(h.ended_at),
      lock: "FOR UPDATE"
    )
    |> AdminRepo.one()
  end

  defp create_holder(changeset, now, opts) do
    holder =
      changeset
      |> Ecto.Changeset.put_change(:last_seen_at, now)
      |> Ecto.Changeset.put_change(:lease_until, DateTime.add(now, lease_seconds(), :second))
      |> AdminRepo.insert()
      |> rollback_on_error()

    {raw_key, api_key} = mint_credential(holder)
    audit!(holder, "registered", %{"api_key_id" => api_key.id}, opts)
    {%{holder: holder, raw_key: raw_key, api_key: api_key, outcome: :created}, []}
  end

  defp rotate_holder(holder, now, opts) do
    hashes = revoke_credentials(holder.tenant_id, holder.id, now)

    holder =
      holder
      |> Ecto.Changeset.change(
        last_seen_at: now,
        lease_until: DateTime.add(now, lease_seconds(), :second)
      )
      |> AdminRepo.update!()

    {raw_key, api_key} = mint_credential(holder)
    audit!(holder, "credential_rotated", %{"api_key_id" => api_key.id}, opts)
    {%{holder: holder, raw_key: raw_key, api_key: api_key, outcome: :rotated}, hashes}
  end

  defp mint_credential(%Holder{} = holder) do
    attrs = %{
      tenant_id: holder.tenant_id,
      name: "holder:#{holder.kind}:#{holder.host}",
      role: :agent,
      agent_id: holder.agent_id,
      expires_at: DateTime.add(holder.lease_until, heartbeat_seconds(), :second)
    }

    case Auth.generate_api_key(attrs, holder_id: holder.id) do
      {:ok, {raw_key, api_key}} -> {raw_key, api_key}
      {:error, changeset} -> AdminRepo.rollback(changeset)
    end
  end

  # --- heartbeat / end ---

  defp owned_holder_for_update(tenant_id, %ApiKey{holder_id: own_id}, holder_id)
       when is_binary(own_id) do
    with {:ok, id} <- cast_id(holder_id),
         true <- id == own_id,
         %Holder{} = holder <-
           AdminRepo.one(
             from(h in Holder,
               where: h.tenant_id == ^tenant_id and h.id == ^id,
               lock: "FOR UPDATE"
             )
           ) do
      {:ok, holder}
    else
      _ -> {:error, :not_found}
    end
  end

  defp owned_holder_for_update(_tenant_id, _caller, _holder_id), do: {:error, :not_found}

  defp cast_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast_id(_), do: :error

  defp refuse_ended(%Holder{ended_at: nil}), do: :ok
  defp refuse_ended(%Holder{}), do: {:error, :holder_ended}

  defp end_live_holder(holder, reason, now, opts) do
    holder =
      holder
      |> Ecto.Changeset.change(ended_at: now, ended_reason: reason)
      |> AdminRepo.update!()

    hashes =
      live_credentials(holder.tenant_id, holder.id)
      |> Enum.map(fn key ->
        case Auth.revoke_api_key(key) do
          {:ok, revoked} -> revoked.key_hash
          {:error, changeset} -> AdminRepo.rollback(changeset)
        end
      end)

    audit!(holder, "ended", %{"reason" => to_string(reason)}, opts)
    {holder, hashes}
  end

  # --- credentials ---

  defp live_credentials(tenant_id, holder_id) do
    from(k in ApiKey,
      where: k.tenant_id == ^tenant_id and k.holder_id == ^holder_id and is_nil(k.revoked_at)
    )
    |> AdminRepo.all()
  end

  defp revoke_credentials(tenant_id, holder_id, now) do
    {_count, hashes} =
      from(k in ApiKey,
        where: k.tenant_id == ^tenant_id and k.holder_id == ^holder_id and is_nil(k.revoked_at),
        select: k.key_hash
      )
      |> AdminRepo.update_all(set: [revoked_at: now, updated_at: now])

    hashes
  end

  defp redate_credentials(tenant_id, holder_id, expires_at) do
    {_count, hashes} =
      from(k in ApiKey,
        where: k.tenant_id == ^tenant_id and k.holder_id == ^holder_id and is_nil(k.revoked_at),
        select: k.key_hash
      )
      |> AdminRepo.update_all(set: [expires_at: expires_at, updated_at: DateTime.utc_now()])

    hashes
  end

  # --- shared ---

  defp audit!(%Holder{} = holder, action, metadata, opts) do
    Multi.new()
    |> Audit.log_in_multi(:audit, fn _ ->
      %{
        tenant_id: holder.tenant_id,
        entity_type: "holder",
        entity_id: holder.id,
        action: action,
        actor_type: Keyword.get(opts, :actor_type, "system"),
        actor_id: Keyword.get(opts, :actor_id),
        actor_label: Keyword.get(opts, :actor_label),
        metadata: Map.merge(Keyword.get(opts, :metadata, %{}), metadata),
        new_state: holder_state(holder)
      }
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _step, changeset, _} -> AdminRepo.rollback(changeset)
    end
  end

  defp holder_state(%Holder{} = holder) do
    %{
      "kind" => to_string(holder.kind),
      "session_id" => holder.session_id,
      "host" => holder.host,
      "worktree" => holder.worktree,
      "agent_id" => holder.agent_id,
      "lease_until" => DateTime.to_iso8601(holder.lease_until),
      "ended_at" => holder.ended_at && DateTime.to_iso8601(holder.ended_at),
      "ended_reason" => holder.ended_reason && to_string(holder.ended_reason)
    }
  end

  defp rollback_on_error({:ok, value}), do: value
  defp rollback_on_error({:error, changeset}), do: AdminRepo.rollback(changeset)

  defp after_commit({:ok, {result, hashes}}) do
    Auth.invalidate_key_cache_by_hashes(hashes)
    {:ok, result}
  end

  defp after_commit({:error, _} = error), do: error
end
