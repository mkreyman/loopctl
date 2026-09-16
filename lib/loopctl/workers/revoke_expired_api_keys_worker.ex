defmodule Loopctl.Workers.RevokeExpiredApiKeysWorker do
  @moduledoc """
  Revokes `api_keys` rows whose TTL has passed, so that "expired" and "revoked"
  stop being two different answers to the question *is this key active?*

  ## The defect this closes

  `api_keys_one_role_per_agent_idx` (`priv/repo/migrations/20260411233503_enforce_api_key_invariants.exs`)
  is a PARTIAL UNIQUE index over `(tenant_id, agent_id, role)` with the predicate
  `revoked_at IS NULL AND role NOT IN ('user','superadmin')`. It is the invariant
  that one agent holds at most one usable key per role. **`expires_at` is not in
  that predicate and cannot be**: a partial index predicate must be IMMUTABLE and
  `now()` is STABLE, so Postgres refuses `AND expires_at > now()` outright.

  So the index's notion of "active" is `revoked_at IS NULL`, while the auth
  pipeline's is `revoked_at IS NULL AND expires_at > now()`
  (`Loopctl.Auth.load_active_api_key/1`). An expired key satisfies the first and
  fails the second: unusable for authentication, yet still OCCUPYING its agent's
  slot. The next mint for that agent at that role fails with
  `agent already has an active key with this role`
  (`Loopctl.Auth.ApiKey`'s `unique_constraint/3` message) — a 422 naming a key
  that every human-readable description calls gone.

  Since the index cannot test expiry, the two notions are made to agree the only
  other way: expiry is REAPED rather than tested, exactly as
  `Loopctl.Workers.ReclaimExpiredClaimsWorker` reaps a story lease the row cannot
  test either.

  ## Why the dispatch sweep does not already cover it

  `Loopctl.Workers.RevokeExpiredDispatchesWorker` revokes an expired DISPATCH and
  cascades to the key it minted, so every dispatch-minted key is already swept —
  its `expires_at` is the dispatch's own (`Dispatches.mint_and_link_key/4` passes
  it through), so the two expire together.

  A key minted directly at `POST /api/v1/api_keys` with an `expires_at` has no
  dispatch row at all, and nothing anywhere revoked it. At `role: :agent` with an
  `agent_id`, such a key held its slot PERMANENTLY — the mint refusal above with
  no expiry that would ever clear it. This worker is the sweep for those; it is
  keyed on the `api_keys` row rather than on a dispatch, so it covers every mint
  path including any added later — but only for the keys the index actually
  CONSTRAINS (see Scope).

  ## Scope, deliberately

  * **EXACTLY the keys the index CONSTRAINS — which is narrower than the roles it
    names.** A row is constrained by `api_keys_one_role_per_agent_idx` only if it
    satisfies the index predicate AND carries no NULL in the index's key columns
    `(tenant_id, agent_id, role)`: a Postgres unique index treats NULLs as DISTINCT
    unless it is declared `NULLS NOT DISTINCT`, and this one is not
    (`priv/repo/migrations/20260411233503_enforce_api_key_invariants.exs:43-46`), so a
    row with a NULL key column conflicts with nothing and occupies no slot. `role` is
    required (`validate_required([:name, :role])`, `lib/loopctl/auth/api_key.ex:91`)
    and `tenant_id` is NOT NULL at every non-superadmin role (the CHECK
    `api_keys_superadmin_iff_null_tenant`,
    `priv/repo/migrations/20260703130000_add_role_tenant_check_to_api_keys.exs:20-23`),
    so `agent_id` is the only one that can be NULL here. Hence the predicate:
    `role NOT IN ('user','superadmin') AND agent_id IS NOT NULL`.

    **`agent_id IS NULL` at an INDEXED role is a reachable state, not a hypothetical.**
    Nothing requires the column: the create changeset validates `[:name, :role]` only
    (`lib/loopctl/auth/api_key.ex:91`), and the CHECK that would have required it was
    DEFERRED and never added — see the comment at
    `priv/repo/migrations/20260411233503_enforce_api_key_invariants.exs:34-37`
    promising it for US-26.2.1, and the only api_keys CHECK that did land
    (`20260703130000_add_role_tenant_check_to_api_keys.exs`) constrains `tenant_id`,
    not `agent_id`. `LoopctlWeb.StoryVerificationController.validate_orchestrator_agent_linked/1`
    (`lib/loopctl_web/controllers/story_verification_controller.ex:508-515`) returns a
    400 for exactly this shape, which is what says it occurs.

    Why NARROW rather than sweep everything expired: `revoked_at` is load-bearing on
    two OTHER surfaces, so reaping a key that holds no slot costs something and buys
    nothing. `POST /api/v1/api_keys/:id/rotate` refuses a REVOKED key outright
    (`validate_not_revoked/1`, `api_key_controller.ex:218-221`) while an EXPIRED one
    rotates fine, so sweeping such a key destroys the recovery path for its own
    credential — mint a replacement with the same name and role — and for a `user` key
    that is often the ONLY way back. And `GET /api/v1/api_keys` defaults to
    `include_revoked: false` (`api_key_controller.ex:157-161`), so the key would vanish
    from the listing as well: the operator could neither see it nor rotate it. Both
    were undocumented consequences of a broader sweep (#862 review, finding 6).

    **And rotation really is already impossible for the keys this DOES sweep — that
    is what makes the exclusion coherent rather than arbitrary.** For an INDEXED key
    `do_rotate_key/3` (`api_key_controller.ex:259`) mints a replacement at the same
    `(tenant_id, agent_id, role)` while `Auth.expire_api_key/2` only sets `expires_at`
    on the old row, leaving it `revoked_at IS NULL` — so the partial unique index
    refuses the insert and this sweep takes nothing those keys had. For an
    `agent_id IS NULL` key the index refuses NOTHING, so rotation works today and a
    sweep WOULD take it away. That subset is the half round 1 got wrong (#862 review
    round 2, finding 1): the moduledoc cited the rotation asymmetry as its reason for
    excluding `user`/`superadmin` while the narrowing it justified still covered keys
    for which the asymmetry does not hold — no slot freed, the rotate path destroyed.

    The cost accepted: an expired key OUTSIDE the index — `user`/`superadmin`, or any
    role with a NULL `agent_id` — stays `revoked_at IS NULL` for ever. That was a COUNT
    being cosmetic, weighed against a recovery path being destroyed, and the counters
    have since been fixed rather than this sweep widened (846.8, AC-2):
    `Loopctl.Tenants`' private `active_api_keys/0` is the one predicate behind the operator-facing
    "active keys" counts (`Loopctl.Tenants.list_tenants_admin/1` and `get_tenant_admin/1`
    via `tenant_with_stats/1`, and `system_stats/0` via `count_active_api_keys/0`) and it
    tests expiry as well as revocation, matching `Loopctl.Auth.load_active_api_key/1`.
    Those are ordinary queries and may test `expires_at` freely; the partial unique index
    may not. **So this sweep is not, and must not become, what makes a count true** —
    widening it here to converge a number is the trade this section already refused.
  * **A NULL `expires_at` is never touched.** That is a non-expiring key —
    every legacy env-var key is one — and it is live by both notions.
  * **An already-revoked key is never touched**, so the sweep is idempotent and
    never rewrites a revocation timestamp that an audit reader may be relying on.

  Bounded at `@batch` keys per run, oldest expiry first, so a backlog drains over
  successive runs instead of pinning AdminRepo's small (3-connection) pool.
  Cross-tenant by design, like the dispatch sweep: the predicate is expiry, not
  tenancy, and it runs on `AdminRepo` (BYPASSRLS) where the explicit predicates
  are the only scoping there is.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey

  @batch 500

  # The partial unique index's OWN exclusion, `role NOT IN ('user','superadmin')`
  # (`priv/repo/migrations/20260411233503_enforce_api_key_invariants.exs:43-46`). A key at one
  # of these roles occupies no slot, so reaping it buys nothing and costs the operator its
  # `rotate` path — see the Scope section of the moduledoc.
  #
  # It is only HALF the exclusion: `agent_id IS NULL` puts a key outside the index too, for a
  # reason the index's TEXT does not show. See `sweepable/2`.
  @roles_outside_index [:user, :superadmin]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    case expired_key_ids(now) do
      [] -> :ok
      ids -> revoke_batch(ids, now)
    end
  end

  @doc false
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  @doc """
  Revokes the subset of `ids` that STILL satisfies the sweep predicate, at `now`.

  Public as a TEST SEAM, and that is not cosmetic. This statement
  re-asserts `sweepable/2` over ids the candidate read already filtered, so through
  `perform/1` the two guards are REDUNDANT and each masks the other: deleting either
  one on its own leaves every assertion green, which is a check that cannot fail.
  Reaching this half directly is what makes the re-assertion falsifiable.

  The re-assertion is not redundant in production. The candidate read is ADVISORY —
  the same shape `ReclaimExpiredClaimsWorker` uses — so a key revoked, or given a
  later expiry, between the read and the write must not be rewritten on the strength
  of a stale read. That is also why the count comes from the UPDATE and never from
  the candidate list.
  """
  @spec revoke_batch([Ecto.UUID.t()], DateTime.t()) :: :ok
  def revoke_batch(ids, now) do
    {count, key_hashes} =
      from(k in ApiKey, where: k.id in ^ids, select: k.key_hash)
      |> sweepable(now)
      |> AdminRepo.update_all(set: [revoked_at: now])

    # The `update_all` cascade bypasses changesets, so the api-key cache is busted
    # explicitly for every revoked hash (AC-33.3.2). The hashes come back from the
    # revoke statement itself, so invalidation costs no second AdminRepo lookup on
    # the pool this cache exists to relieve (US-33.3, finding-4).
    #
    # A cached entry would have been REJECTED anyway — `ApiKeyCache` re-checks the
    # wall clock on every hit (AC-33.3.5) — so this is not what makes an expired
    # key unusable. It is what stops a stale entry outliving the row's revocation.
    Auth.invalidate_key_cache_by_hashes(key_hashes)

    Logger.info("RevokeExpiredApiKeysWorker: revoked #{count} expired api_keys")

    :ok
  end

  defp expired_key_ids(now) do
    from(k in ApiKey,
      order_by: [asc: k.expires_at],
      limit: @batch,
      select: k.id
    )
    |> sweepable(now)
    |> AdminRepo.all()
  end

  # THE sweep predicate, written ONCE and composed onto both statements.
  #
  # It was written twice, and the duplication was worse than untidy: the two copies
  # made each other unfalsifiable. Deleting the `revoked_at` guard from the candidate
  # read left the UPDATE refusing the row; deleting it from the UPDATE left the
  # candidate read never offering the row. Both mutations came back green
  # (`bin/mutate.sh` exit 1, twice) against a suite that does assert the behaviour —
  # the classic redundant-guard pair, where the check passes whatever either half does.
  #
  # "Active" here is the AUTH pipeline's notion (`Auth.load_active_api_key/1`), which
  # the partial unique index cannot share: a partial-index predicate must be IMMUTABLE
  # and `now()` is STABLE, so the index can only test `revoked_at IS NULL`. Reaping is
  # what makes the two agree.
  #
  # `not is_nil(k.agent_id)` is the half the index's own TEXT does not show, and leaving it
  # out was #862 review round 2, finding 1. The index is keyed on `(tenant_id, agent_id,
  # role)` and is NOT declared `NULLS NOT DISTINCT`
  # (`priv/repo/migrations/20260411233503_enforce_api_key_invariants.exs:43-46`), so Postgres
  # treats every NULL `agent_id` as distinct from every other: such a row conflicts with
  # nothing and occupies NO slot, at ANY role. Nothing forbids the state either — the create
  # changeset requires `[:name, :role]` only (`lib/loopctl/auth/api_key.ex:91`) and the CHECK
  # that would have required `agent_id` was deferred and never added (`:34-37` of the same
  # migration). So sweeping those keys frees nothing while taking away the `rotate` path
  # `validate_not_revoked/1` leaves open for an expired key — exactly the harm the role
  # exclusion above exists to avoid, inflicted on a subset it does not cover.
  defp sweepable(query, now) do
    where(
      query,
      [k],
      is_nil(k.revoked_at) and not is_nil(k.expires_at) and k.expires_at < ^now and
        k.role not in ^@roles_outside_index and not is_nil(k.agent_id)
    )
  end
end
