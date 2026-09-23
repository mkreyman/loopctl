defmodule Loopctl.Workers.ReclaimExpiredClaimsWorker do
  @moduledoc """
  #803 — Releases story claims whose lease (`stories.claimed_until`) has run out.
  Runs every 5 minutes via Oban Cron. Modelled on `RevokeExpiredDispatchesWorker`.

  The sweep reads a bounded CANDIDATE list on AdminRepo (BYPASSRLS, so the explicit
  predicates are the only scoping) and releases each through
  `Loopctl.Progress.reclaim_expired_claim/3`, which re-checks everything under the
  story's row lock and scopes its own lock by `(id, tenant_id)` from the same row. The
  read is therefore only advisory: a claim renewed, released or reported between the
  read and the lock is skipped, and two overlapping runs cannot release a story twice.

  What it deliberately leaves alone:

  - **A NULL lease.** Every claim made before the lease existed has one, and nothing
    renews those claims — so a lease applied retroactively would release in-flight work.
    The predicate excludes NULL outright.
  - **`reported_done`.** A reported story is in custody review, not held by a claimant.
  - **A story whose review has been requested** (`review_requested_at` set). It stays
    `implementing` until a different principal reports it, and only the implementer can
    renew, so the implementer's lease stops applying at the hand-off.
  - **A tenant whose claimants cannot renew**: one under a custody halt (`renew-claim` is
    custody surface) or one whose status is anything but `:active` (`ResolveApiKey` 403s
    every request from it — suspended, deactivated, pending enrollment). Skipping them
    here only DEFERS a reclaim, so two more things hold it: the release re-checks both
    under a share lock on the tenant row (`Progress.reclaim_expired_claim/3`), and each
    transition that makes renewal possible again — `Tenants.clear_custody_halt/1` and
    `Tenants.activate_tenant/1` — extends every live lease by one renewal grace in the same
    transaction, so a lease that ran out meanwhile is not reclaimed before its claimant
    has had a full lease to renew.

  Bounded at `@batch` stories per run, so a backlog drains over successive runs instead of
  pinning AdminRepo's small pool — and ranked WITHIN EACH TENANT, taking every tenant's first
  before any tenant's second (`candidates/2`). Ranked globally, one tenant whose releases keep
  failing held the head of every run with its oldest leases and starved every other tenant's
  reclaim (#877 review round 2).

  Within a tenant, a lease whose release FAILED OR RAISED is stamped
  `stories.lease_reclaim_failed_at` after the pass, and ranks behind every lease never stamped
  (#877 review round 3). Ranked oldest lease first alone, a tenant with more failing leases than
  its share of the batch — a per-story poison, not a broken chain — gave every one of its slots
  to them on every run and never reached its healthy leases. The stamp is written by this worker
  only, never cast, and cleared by every release (`Progress.claim_release_change/1`), so it
  describes the lease it failed on and never the story's next one.

  A candidate whose release RAISES is logged ONCE, at error, naming the exception's MODULE and
  its stack trace — never its message, which for a database error can quote the story row — then
  the pass goes on.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Progress
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Story

  @batch 100

  # Refusals that mean "not this time", decided under the row lock — not failures.
  @skip_reasons [:claim_not_expired, :custody_halted, :tenant_inactive]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    candidates = candidates(now, @batch)

    results =
      Enum.map(candidates, fn candidate ->
        result = reclaim(candidate)
        log_candidate(candidate, result)
        result
      end)

    candidates
    |> Enum.zip(results)
    |> Enum.filter(fn {_candidate, result} -> failed?(result) end)
    |> Enum.each(fn {candidate, _result} -> mark_failed(candidate, now) end)

    reclaimed = Enum.count(results, &match?({:ok, _}, &1))

    skipped =
      Enum.count(results, &match?({:error, reason} when reason in @skip_reasons, &1))

    failed = length(results) - reclaimed - skipped

    if results != [] do
      Logger.info(
        "ReclaimExpiredClaimsWorker: reclaimed=#{reclaimed} skipped=#{skipped} failed=#{failed}"
      )
    end

    :ok
  end

  # ONE STORY CANNOT END THE PASS (#877 review round 1). A candidate whose release RAISES — a
  # database error inside its transaction, which rolls that one release back — would otherwise
  # abort the run at that story and, since it is still expired, at the same story next run.
  # The raise becomes that candidate's failure and the pass goes on. Nothing is committed for
  # it: the raise left its transaction, which rolled back. Rescued, it is also NOT seen by
  # Oban, so it is logged here, ONCE — `log_candidate/2` does not log it again. The MODULE and
  # the stack, never `Exception.message/1`: a database error's message can quote the row.
  defp reclaim(candidate) do
    Progress.reclaim_expired_claim(candidate.tenant_id, candidate.id, candidate.claim_epoch)
  rescue
    error ->
      Logger.error(
        "ReclaimExpiredClaimsWorker: release raised: tenant_id=#{candidate.tenant_id} " <>
          "story_id=#{candidate.id} exception=#{inspect(error.__struct__)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__),
        tenant_id: candidate.tenant_id,
        story_id: candidate.id
      )

      {:error, {:raised, error.__struct__}}
  end

  defp failed?({:ok, _story}), do: false
  defp failed?({:error, reason}), do: reason not in @skip_reasons

  # Stamps the lease that failed — at the epoch it was read at, so a lease that was released
  # and re-claimed meanwhile is not stamped — AFTER the pass, so a stamp that raises cannot cut
  # the pass short.
  @doc false
  # Public only so the epoch fence can be asserted directly.
  def mark_failed(candidate, now) do
    from(s in Story,
      where:
        s.id == ^candidate.id and s.tenant_id == ^candidate.tenant_id and
          s.claim_epoch == ^candidate.claim_epoch
    )
    |> AdminRepo.update_all(set: [lease_reclaim_failed_at: now])
  end

  # Issue #815: the summary line only counts. This names every candidate that was not
  # skipped: a reclaim (which ends a claimant's lease, so its runner will be fenced) and a
  # failure. A skip is decided under the row lock and is routine, so it stays out.
  defp log_candidate(candidate, {:ok, story}) do
    Logger.info(
      "ReclaimExpiredClaimsWorker: reclaimed: tenant_id=#{candidate.tenant_id} " <>
        "story_id=#{candidate.id} claim_epoch=#{candidate.claim_epoch} " <>
        "new_claim_epoch=#{story.claim_epoch} reason=:claim_lease_expired",
      tenant_id: candidate.tenant_id,
      story_id: candidate.id,
      claim_epoch: candidate.claim_epoch
    )
  end

  defp log_candidate(_candidate, {:error, reason}) when reason in @skip_reasons, do: :ok

  # Already logged at error by `reclaim/1`, with its stack.
  defp log_candidate(_candidate, {:error, {:raised, _module}}), do: :ok

  defp log_candidate(candidate, {:error, reason}) do
    Logger.warning(
      "ReclaimExpiredClaimsWorker: reclaim failed: tenant_id=#{candidate.tenant_id} " <>
        "story_id=#{candidate.id} claim_epoch=#{candidate.claim_epoch} " <>
        "reason=#{inspect(failure_reason(reason))}",
      tenant_id: candidate.tenant_id,
      story_id: candidate.id,
      claim_epoch: candidate.claim_epoch
    )
  end

  # A changeset is summarised by its errors; its data is a story row and stays out of logs.
  defp failure_reason(%Ecto.Changeset{errors: errors}),
    do: {:invalid_changeset, Keyword.keys(errors)}

  defp failure_reason(reason), do: reason

  @doc false
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  @doc """
  The expired claims one run releases, at most `limit`: ranked WITHIN each tenant
  (`row_number()` over the tenant, as `Loopctl.Delivery.TriageDispatcher.candidates/1` ranks),
  then by that rank — so every tenant's first comes before any tenant's second, and one
  tenant's failing leases cannot fill the batch. Within a tenant, leases never stamped
  `lease_reclaim_failed_at` come first, oldest lease first, then the stamped ones, so a
  tenant's failing leases cannot hold its own healthy ones back either. Public so the selection
  is falsifiable.
  """
  @spec candidates(DateTime.t(), pos_integer()) :: [
          %{id: Ecto.UUID.t(), tenant_id: Ecto.UUID.t(), claim_epoch: non_neg_integer()}
        ]
  def candidates(now, limit) when is_integer(limit) and limit > 0 do
    ranked =
      from(s in Story,
        join: t in Tenant,
        on: t.id == s.tenant_id,
        where:
          not is_nil(s.claimed_until) and s.claimed_until < ^now and
            is_nil(s.review_requested_at) and s.agent_status in [:assigned, :implementing] and
            t.status == :active and is_nil(t.custody_halted_at),
        select: %{
          id: s.id,
          tenant_id: s.tenant_id,
          claim_epoch: s.claim_epoch,
          claimed_until: s.claimed_until,
          rank:
            over(row_number(),
              partition_by: s.tenant_id,
              order_by: [
                asc_nulls_first: s.lease_reclaim_failed_at,
                asc: s.claimed_until,
                asc: s.id
              ]
            )
        }
      )

    from(r in subquery(ranked),
      order_by: [asc: r.rank, asc: r.claimed_until, asc: r.id],
      limit: ^limit,
      select: %{id: r.id, tenant_id: r.tenant_id, claim_epoch: r.claim_epoch}
    )
    |> AdminRepo.all()
  end
end
