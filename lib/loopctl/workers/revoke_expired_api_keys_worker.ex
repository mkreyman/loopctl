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
  path including any added later.

  ## Scope, deliberately

  * **Every role, not just the indexed ones.** The index ignores `user` and
    `superadmin`, but an expired key of any role that still reads as un-revoked
    also inflates the operator-facing "active keys" counts
    (`Loopctl.Tenants.tenant_stats/1`, `count_active_api_keys/0`), which likewise
    test `revoked_at IS NULL` alone. Revoking an already-expired key grants
    nothing and takes nothing away: `load_active_api_key/1` had rejected it since
    the moment it expired.
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

  Public (`@doc false`) as a TEST SEAM, and that is not cosmetic. This statement
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
  defp sweepable(query, now) do
    where(
      query,
      [k],
      is_nil(k.revoked_at) and not is_nil(k.expires_at) and k.expires_at < ^now
    )
  end
end
