defmodule Loopctl.Workers.ChannelClaimSweeper do
  @moduledoc """
  Oban cron worker that reclaims spent coordination-bus CLAIMS
  (`Loopctl.Coordination.ChannelClaim`), Epic 40 / US-40.B1.

  Unlike `Loopctl.Workers.ChannelPostSweeper` (a uniform `expires_at < now()` TTL),
  a claim sweep is LIFECYCLE-AWARE and MUST NEVER delete an OPEN, unexpired claim —
  doing so would silently steal a handoff a live agent still holds. It removes ONLY:

    * **DONE claims past retention, WHOSE HANDOFF POST IS NO LONGER LIVE** —
      `done_at IS NOT NULL AND done_at < now() - #{7}d`
      (`Coordination.claim_done_retention_days/0` is the single source of truth)
      **AND** no live `channel_posts` row shares the claim's `ref`
      (`NOT EXISTS (post WHERE key = claim.ref AND expires_at > now())`, same
      tenant/project). A done claim is kept as an audit/idempotency breadcrumb for
      at least the retention window AND for as long as the handoff post it
      terminates is still discoverable, then reaped.

      The live-post guard is the TERMINAL-GUARANTEE COUPLING (US-40.C1, high
      finding). `Coordination.directed_handoffs/3` encodes a completed handoff's
      terminality SOLELY through the presence of its DONE claim row (the correlated
      `NOT EXISTS(active_claim)`: `channel_claims.ref = channel_posts.key`). If this
      sweeper reaped that DONE claim while the post was still live (posts live 30d
      via `Coordination.retention_days/0`; a DONE claim's own 7d retention is far
      shorter, AND the upsert FULL-REPLACE path can even RE-EXTEND a post's
      `expires_at`), the freed `(tenant_id, project_id, ref)` slot would let the
      finished handoff both REAPPEAR in the pinned discovery set and accept a fresh
      re-claim (double-done). Retaining the DONE claim while ANY live post shares
      its ref makes "a DONE handoff never reappears" DURABLY true for the post's
      whole life, without coupling two independent numeric retentions.
    * **Abandoned leases** — `done_at IS NULL AND lease_expires_at < now()`. The
      claimant's lease expired without a `done`, so the ref REOPENS for the next
      racer (the deleted row frees the `(tenant_id, project_id, ref)` unique slot).

  It deliberately does NOT apply the uniform 30-day `channel_posts` sweep to claims,
  and it never touches `done_at IS NULL AND lease_expires_at >= now()` (an open,
  unexpired claim).

  The two predicates are tenant-independent, so the delete runs once across all
  tenants on the BYPASSRLS `Loopctl.AdminRepo` (never a per-tenant loop);
  `channel_claims` has RLS ENABLED as defense-in-depth, but the sweep touches no
  tenant column. Scheduled via the Oban Cron plugin in `Loopctl.ObanConfig.plugins/0`
  (every 5 minutes). Bounded per run (a SINGLE batch of at most `@batch_size`,
  non-recursive) — a large backlog drains over successive runs rather than locking
  the table in one long transaction (same discipline as `ChannelPostSweeper`). The
  bound is overridable via the `"limit"` job arg. Idempotent — a no-op when nothing
  is reclaimable.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelClaim
  alias Loopctl.Coordination.ChannelPost

  @batch_size 1000

  @doc """
  Reclaims at most one batch of spent claims (done-past-retention OR
  abandoned-lease). Reads the `"limit"` job arg (a positive integer) as the per-run
  batch bound, defaulting to `#{@batch_size}`. Returns `:ok` whether or not anything
  was deleted (idempotent); logs the count only when it is positive.
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: args}) do
    now = DateTime.utc_now()
    done_cutoff = DateTime.add(now, -Coordination.claim_done_retention_days() * 86_400, :second)
    limit = batch_limit(args)

    # The lifecycle-aware reclaim predicate (AC-40.B1.4): a DONE claim past retention
    # WHOSE handoff post is no longer live, OR an abandoned (expired-lease, not-done)
    # claim. NEVER an open, unexpired claim (`done_at IS NULL AND
    # lease_expires_at >= now()` is excluded by construction), and NEVER a DONE claim
    # while a live post still shares its ref (the terminal-guarantee coupling — see
    # the moduledoc and `live_post_exists/1`).
    ids =
      from(c in ChannelClaim, as: :claim)
      |> where(
        [c],
        (not is_nil(c.done_at) and c.done_at < ^done_cutoff and
           not exists(live_post_exists(now))) or
          (is_nil(c.done_at) and c.lease_expires_at < ^now)
      )
      |> select([c], c.id)
      |> limit(^limit)
      |> AdminRepo.all()

    case ids do
      [] ->
        :ok

      batch_ids ->
        {count, _} =
          ChannelClaim
          |> where([c], c.id in ^batch_ids)
          |> AdminRepo.delete_all()

        if count > 0 do
          Logger.info("ChannelClaimSweeper reclaimed #{count} spent channel claims")
        end

        :ok
    end
  end

  # Correlated NOT-EXISTS probe for a LIVE handoff post sharing this claim's ref —
  # the same `channel_claims.ref = channel_posts.key` (+ tenant/project) correlation
  # `Coordination.directed_handoffs/3` uses to gate discovery. While such a post is
  # live (`expires_at > now`), the DONE claim that makes it terminal must be RETAINED
  # so the finished handoff can neither reappear nor accept a re-claim. `parent_as(:claim)`
  # correlates to the outer sweep query's `:claim` binding. A claim whose ref matches
  # no live post (an already-expired handoff, or a non-handoff ref) is unguarded and
  # reaps normally on the retention window.
  defp live_post_exists(now) do
    from(p in ChannelPost,
      where:
        p.tenant_id == parent_as(:claim).tenant_id and
          p.project_id == parent_as(:claim).project_id and
          p.key == parent_as(:claim).ref and
          p.expires_at > ^now
    )
  end

  # Clamped to @batch_size: the selected ids are passed as an explicit list to
  # `where(c.id in ^batch_ids)`, one bind parameter each, so an unbounded limit
  # >= 65536 would exceed Postgres's 65535-parameter cap. Capping keeps the id-list
  # well under the limit while letting an operator shrink the per-run cap.
  defp batch_limit(%{"limit" => limit}) when is_integer(limit) and limit > 0,
    do: min(limit, @batch_size)

  defp batch_limit(_args), do: @batch_size
end
