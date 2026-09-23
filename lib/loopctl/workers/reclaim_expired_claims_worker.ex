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
  pinning AdminRepo's small pool — and ranked oldest lease first WITHIN EACH TENANT, taking
  every tenant's oldest before any tenant's second (`candidates/2`). Ranked globally, one
  tenant whose releases keep failing held the head of every run with its oldest leases and
  starved every other tenant's reclaim (#877 review round 2). Within a tenant, a broken chain
  blocking its own reclaims is the correct outcome: that tenant's custody transitions are all
  failing until an operator acts.

  A candidate whose release RAISES is logged at error with its stack trace and emits
  `[:loopctl, :reclaim_expired_claims, :raised]` (count 1, metadata `tenant_id`, `story_id`,
  `exception`), then the pass goes on.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Progress
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Story

  @batch 100

  @raised_event [:loopctl, :reclaim_expired_claims, :raised]

  # Refusals that mean "not this time", decided under the row lock — not failures.
  @skip_reasons [:claim_not_expired, :custody_halted, :tenant_inactive]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    results =
      now
      |> candidates(@batch)
      |> Enum.map(fn candidate ->
        result = reclaim(candidate)
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

  # ONE STORY CANNOT END THE PASS (#877 review round 1). A candidate whose release RAISES — a
  # database error inside its transaction, which rolls that one release back — would otherwise
  # abort the run at that story and, since it is still expired, at the same story next run.
  # The raise becomes that candidate's failure and the pass goes on. Nothing is committed for
  # it: the raise left its transaction, which rolled back. Rescued, it is also NOT seen by
  # Oban, so the full exception and stack trace are logged here and a telemetry event is
  # emitted — the failure reason alone names only the module and message.
  defp reclaim(candidate) do
    Progress.reclaim_expired_claim(candidate.tenant_id, candidate.id, candidate.claim_epoch)
  rescue
    error ->
      Logger.error(
        "ReclaimExpiredClaimsWorker: release raised: tenant_id=#{candidate.tenant_id} " <>
          "story_id=#{candidate.id}\n" <> Exception.format(:error, error, __STACKTRACE__),
        tenant_id: candidate.tenant_id,
        story_id: candidate.id
      )

      :telemetry.execute(@raised_event, %{count: 1}, %{
        tenant_id: candidate.tenant_id,
        story_id: candidate.id,
        exception: error.__struct__
      })

      {:error, {:raised, error.__struct__, Exception.message(error)}}
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

  @doc """
  The expired claims one run releases, at most `limit`: ranked oldest lease first WITHIN each
  tenant (`row_number()` over the tenant, as `Loopctl.Delivery.TriageDispatcher.candidates/1`
  ranks), then by that rank — so every tenant's oldest comes before any tenant's second, and
  one tenant's failing leases cannot fill the batch. Public so the selection is falsifiable.
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
              order_by: [asc: s.claimed_until, asc: s.id]
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
