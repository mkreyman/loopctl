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

  ## A holder's claims live by its lease (US-52.19)

  A claim a holder makes without a cap takes the holder's `lease_until`
  (`claim_lease/3`), every heartbeat moves those claims to the new lease in its own
  transaction, and a holder that ends, by its own end, a late heartbeat or the sweep
  (`end_lapsed/2`), releases them in the end's transaction. Capped claims (a runner's
  dispatch lease) keep their cap. The values and the measurement behind them:
  `docs/factory/measurements/session-holder-lease.md`.

  Lock order: a holder row before story rows. The claim path reads the holder after taking
  the story lock, but without locking it, so no cycle is added.

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
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Holders.Holder
  alias Loopctl.Progress
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Story

  @default_lease_seconds 300
  @default_heartbeat_seconds 60
  @self_kinds [:interactive, :cloud]
  @claimed_statuses [:assigned, :implementing]

  @type register_result :: %{
          holder: Holder.t(),
          raw_key: String.t(),
          api_key: ApiKey.t(),
          outcome: :created | :rotated
        }

  @doc """
  The measured default lease, five heartbeat intervals
  (`docs/factory/measurements/session-holder-lease.md`).
  """
  @spec default_lease_seconds() :: pos_integer()
  def default_lease_seconds, do: @default_lease_seconds

  @doc "The measured default heartbeat interval."
  @spec default_heartbeat_seconds() :: pos_integer()
  def default_heartbeat_seconds, do: @default_heartbeat_seconds

  @doc """
  How long a holder's lease runs from its last heartbeat: `:holder_lease_seconds`, set from
  `HOLDER_LEASE_SECONDS`, default #{@default_lease_seconds}, the value US-52.19 measured.
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

  Sets `last_seen_at` to now and `lease_until` to now plus `lease_seconds/0`, moves the
  credential's `expires_at` to the new lease plus one heartbeat interval, and moves every
  uncapped claim the holder holds to the new lease (US-52.19), all in one transaction. A
  claim only ever moves FORWARD, so a repeated heartbeat changes nothing.

  A holder that is not `caller`'s is `:not_found` (no existence oracle); an ended one is
  `:holder_ended`. A heartbeat that arrives after the lease ran out is
  `:holder_lease_expired`, and it COMMITS the end: the holder ends `:lapsed`, its credential
  is revoked and its claims are released, so the session registers again as a new holder.
  """
  @spec heartbeat(Ecto.UUID.t(), ApiKey.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Holder.t()} | {:error, :not_found | :holder_ended | :holder_lease_expired}
  def heartbeat(tenant_id, %ApiKey{} = caller, holder_id, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    AdminRepo.transaction(fn ->
      with {:ok, holder} <- owned_holder_for_update(tenant_id, caller, holder_id),
           :ok <- refuse_ended(holder) do
        beat_or_lapse(holder, now, opts)
      else
        {:error, reason} -> AdminRepo.rollback(reason)
      end
    end)
    |> after_commit()
    |> case do
      {:ok, {:lapsed, _holder}} -> {:error, :holder_lease_expired}
      other -> other
    end
  end

  defp beat_or_lapse(holder, now, opts) do
    if DateTime.after?(holder.lease_until, now) do
      renew_holder(holder, now)
    else
      {ended, hashes, releases} = end_live_holder(holder, :lapsed, now, opts)
      {{:lapsed, ended}, hashes, releases}
    end
  end

  defp renew_holder(holder, now) do
    lease_until = DateTime.add(now, lease_seconds(), :second)

    holder =
      holder
      |> Ecto.Changeset.change(last_seen_at: now, lease_until: lease_until)
      |> AdminRepo.update!()

    hashes =
      redate_credentials(
        holder.tenant_id,
        holder.id,
        DateTime.add(lease_until, heartbeat_seconds(), :second)
      )

    move_claims(holder, lease_until, now)
    {holder, hashes}
  end

  # Story rows after the holder row (see the moduledoc's lock order). NULL `claimed_until`
  # never compares, so a claim without a lease is never given one here.
  defp move_claims(holder, lease_until, now) do
    from(s in Story,
      where:
        s.tenant_id == ^holder.tenant_id and s.assigned_holder_id == ^holder.id and
          s.agent_status in ^@claimed_statuses and is_nil(s.claim_lease_cap) and
          s.claimed_until < ^lease_until
    )
    |> AdminRepo.update_all(set: [claimed_until: lease_until, updated_at: now])
  end

  @doc """
  The lease an uncapped claim by holder `holder_id` takes (US-52.19): the holder's
  `lease_until`, or `{:error, :holder_lease_expired}` when that has passed, the holder has
  ended, or no such holder is in the tenant. Read without a lock, under the caller's story
  lock (the moduledoc's lock order).
  """
  @spec claim_lease(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, :holder_lease_expired}
  def claim_lease(tenant_id, holder_id, %DateTime{} = now) do
    from(h in Holder,
      where: h.tenant_id == ^tenant_id and h.id == ^holder_id,
      select: {h.lease_until, h.ended_at}
    )
    |> AdminRepo.one()
    |> case do
      {%DateTime{} = lease_until, nil} ->
        if DateTime.after?(lease_until, now),
          do: {:ok, lease_until},
          else: {:error, :holder_lease_expired}

      _ ->
        {:error, :holder_lease_expired}
    end
  end

  @doc """
  Ends the holder `holder_id`, by its own credential `caller`: sets `ended_at`, revokes its
  credential and releases each uncapped claim it holds through `Progress.unclaim_story/3`'s
  path (a `released` item event, reason "holder ended"), in one transaction. A repeated end
  returns the ended holder and writes nothing, so nothing is released twice.
  """
  @spec end_holder(Ecto.UUID.t(), ApiKey.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Holder.t()} | {:error, :not_found}
  def end_holder(tenant_id, %ApiKey{} = caller, holder_id, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    AdminRepo.transaction(fn ->
      case owned_holder_for_update(tenant_id, caller, holder_id) do
        {:ok, %Holder{ended_at: %DateTime{}} = holder} ->
          {holder, [], []}

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
      |> Enum.reduce({nil, [], []}, fn holder, {_last, hashes, releases} ->
        {ended, more, released} = end_live_holder(holder, :ended, now, opts)
        {ended, hashes ++ more, releases ++ released}
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

    move_claims(holder, holder.lease_until, now)
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

  # The one end path: the holder row, its credential, its claims and the audit entry, in the
  # caller's transaction. Returns the released stage rows for `after_commit/1` to announce.
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

    releases = release_claims(holder, reason, opts)
    audit!(holder, "ended", %{"reason" => to_string(reason)}, opts)
    {holder, hashes, releases}
  end

  # Each uncapped claim the holder still holds, released through `unclaim_story/3`'s own
  # Multi so the stage row, the item event, the audit entry and the webhook all follow it. A
  # story whose review was requested is left alone: its implementer's lease stopped applying
  # at the hand-off, exactly as `ReclaimExpiredClaimsWorker` leaves it. Capped claims belong
  # to a dispatch lease and are released by it.
  defp release_claims(holder, reason, opts) do
    from(s in Story,
      where:
        s.tenant_id == ^holder.tenant_id and s.assigned_holder_id == ^holder.id and
          s.assigned_agent_id == ^holder.agent_id and s.agent_status in ^@claimed_statuses and
          is_nil(s.claim_lease_cap) and is_nil(s.review_requested_at),
      order_by: s.id,
      select: s.id
    )
    |> AdminRepo.all()
    |> Enum.map(fn story_id ->
      multi =
        Progress.unclaim_multi(holder.tenant_id, story_id,
          agent_id: holder.agent_id,
          holder_id: holder.id,
          item_reason: "holder #{reason}",
          actor_type: Keyword.get(opts, :actor_type, "system"),
          actor_id: Keyword.get(opts, :actor_id),
          actor_label: Keyword.get(opts, :actor_label, "holder:#{holder.id}")
        )

      case AdminRepo.transaction(multi) do
        {:ok, %{stage: released}} -> released
        {:error, _step, failure, _changes} -> AdminRepo.rollback(failure)
      end
    end)
  end

  # --- the sweep (US-52.19) ---

  @runner_claim_grace_seconds 600

  @doc """
  Ends every holder whose session can no longer be working, with `ended_reason: :lapsed`
  through the one end path (credential revoked, uncapped claims released). Called by
  `Loopctl.Workers.ReclaimExpiredClaimsWorker` AFTER its claim pass. Returns how many ended.

  - **`:interactive` and `:cloud`**: `lease_until` before `now`.
  - **`:runner_session`**: inserted more than #{@runner_claim_grace_seconds} s ago, and either
    no story's `assigned_holder_id` names it, or its dispatch is revoked or expired. Its
    `lease_until` is never read: `Loopctl.Delivery.DispatchLease` moves the claim's cap after
    placement and a story waiting at ci keeps its claim past the cap, so the claim, not the
    holder row, says whether the session may still be working. The grace exists because
    placement commits the holder before the claim (`Loopctl.Delivery.Placement`).

  Tenants under a custody halt or not `:active` are skipped, as the claim pass skips them.
  The read is advisory: each holder is re-checked under its row lock, so a heartbeat or a
  claim that lands meanwhile keeps it live. At most `:limit` (default 100) per run.
  """
  @spec end_lapsed(DateTime.t(), keyword()) :: non_neg_integer()
  def end_lapsed(%DateTime{} = now, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    now
    |> lapsed_query()
    |> order_by([holder: h], asc: h.lease_until, asc: h.id)
    |> limit(^limit)
    |> select([holder: h], {h.tenant_id, h.id})
    |> AdminRepo.all()
    |> Enum.count(fn {tenant_id, holder_id} -> end_lapsed_holder(tenant_id, holder_id, now) end)
  end

  defp end_lapsed_holder(tenant_id, holder_id, now) do
    AdminRepo.transaction(fn ->
      now
      |> lapsed_query()
      |> where([holder: h], h.tenant_id == ^tenant_id and h.id == ^holder_id)
      |> lock("FOR UPDATE OF h0")
      |> AdminRepo.one()
      |> case do
        nil ->
          {nil, [], []}

        %Holder{} = holder ->
          end_live_holder(holder, :lapsed, now, actor_label: "worker:reclaim_expired_claims")
      end
    end)
    |> after_commit()
    |> case do
      {:ok, %Holder{}} ->
        true

      {:ok, nil} ->
        false

      {:error, reason} ->
        Logger.warning(
          "Holders.end_lapsed: end failed: tenant_id=#{tenant_id} holder_id=#{holder_id} " <>
            "reason=#{inspect(failure_reason(reason))}"
        )

        false
    end
  end

  defp failure_reason(%Ecto.Changeset{errors: errors}),
    do: {:invalid_changeset, Keyword.keys(errors)}

  defp failure_reason(reason), do: reason

  defp lapsed_query(now) do
    from(h in Holder,
      as: :holder,
      join: t in Tenant,
      on: t.id == h.tenant_id,
      as: :tenant,
      left_join: d in Dispatch,
      on: d.id == h.dispatch_id and d.tenant_id == h.tenant_id,
      as: :dispatch,
      where: is_nil(h.ended_at),
      where: ^tenant_can_renew(),
      where: ^lapsed(now)
    )
  end

  defp lapsed(now), do: dynamic(^self_lapsed(now) or ^runner_session_done(now))

  defp tenant_can_renew,
    do: dynamic([tenant: t], t.status == :active and is_nil(t.custody_halted_at))

  defp self_lapsed(now),
    do: dynamic([holder: h], h.kind in ^@self_kinds and h.lease_until < ^now)

  defp runner_session_done(now) do
    grace_cutoff = DateTime.add(now, -@runner_claim_grace_seconds, :second)

    holds_nothing =
      dynamic(
        [holder: h],
        not exists(
          from(s in Story,
            where:
              s.tenant_id == parent_as(:holder).tenant_id and
                s.assigned_holder_id == parent_as(:holder).id,
            select: 1
          )
        )
      )

    dispatch_dead =
      dynamic([dispatch: d], not is_nil(d.revoked_at) or d.expires_at < ^now)

    dynamic(
      [holder: h],
      h.kind == :runner_session and h.inserted_at < ^grace_cutoff and
        (^holds_nothing or ^dispatch_dead)
    )
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

  defp after_commit({:ok, {result, hashes, releases}}) do
    Auth.invalidate_key_cache_by_hashes(hashes)
    Enum.each(releases, &Stages.announce_release/1)
    {:ok, result}
  end

  defp after_commit({:error, _} = error), do: error
end
