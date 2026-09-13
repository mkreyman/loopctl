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

  Bounded at `@batch` stories per run, oldest lease first, so a backlog drains over
  successive runs instead of pinning AdminRepo's small pool.
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

    results =
      now
      |> expired_claims()
      |> Enum.map(fn candidate ->
        result =
          Progress.reclaim_expired_claim(candidate.tenant_id, candidate.id, candidate.claim_epoch)

        log_candidate(candidate, result)
        result
      end)

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

  defp expired_claims(now) do
    from(s in Story,
      join: t in Tenant,
      on: t.id == s.tenant_id,
      where:
        not is_nil(s.claimed_until) and s.claimed_until < ^now and
          is_nil(s.review_requested_at) and s.agent_status in [:assigned, :implementing] and
          t.status == :active and is_nil(t.custody_halted_at),
      order_by: [asc: s.claimed_until],
      limit: @batch,
      select: %{id: s.id, tenant_id: s.tenant_id, claim_epoch: s.claim_epoch}
    )
    |> AdminRepo.all()
  end
end
