defmodule Loopctl.Workers.DeliveryLoopPruneWorker do
  @moduledoc """
  #803 (design §11): retention for the delivery loop's two unbounded high-volume tables —
  `runner_trace_events` and the intake delivery log `intake_deliveries`. Hourly via Oban
  Cron. Nothing else deletes from either, so without this both grow for as long as the
  fleet runs.

  The window is a DISK bound, not amnesia. Neither table is the audit chain: a custody
  transition is an append to the hash-chained `audit_log`, which this worker never touches.

  ## What is load-bearing, and therefore never pruned

  Each table's predicate comes from what its rows are USED for, not from their age:

  - **A trace event of a dispatch that is not terminal.** `runner_dispatches.released_at`
    is the one column that says the session is over — a finished run stays `accepted` for
    ever, so `status` cannot say it — and a slot nothing gave back is either still running
    or a leak `Loopctl.Workers.HealRunnerCapacityWorker` releases within the minute. An
    unreleased dispatch keeps its whole trace whatever its age; the failure direction is
    keeping too much. (Resume is unaffected either way: a runner resumes from
    `trace_acked_seq` on the DISPATCH row, and nothing reads events below it. See
    "Retention" in `Loopctl.Runners.DispatchLedger`.)
  - **A delivery row inside GitHub's redelivery window, or one a record still cites.** The
    row IS the idempotency evidence for `(source_id, github_delivery_id)`: delete it and the
    same delivery applies a second time. GitHub keeps roughly 30 days of delivery history
    and its "Redeliver" button reuses the id, so `min_intake_retention_days/0` is the floor
    under any tenant's setting and the default is three times it. A row an
    `intake_records.last_delivery_id` names is kept regardless of age — the provenance of a
    queue entry triage may not have consumed yet. See "Retention" in `Loopctl.Intake`.

  ## Retention windows

  Per tenant, from `tenants.settings` — `runner_trace_retention_days` and
  `intake_delivery_retention_days` — defaulting to `default_trace_retention_days/0` and
  `default_intake_retention_days/0`. They are tenant settings rather than environment
  variables so an operator can widen one tenant's window without a deploy, which is the same
  shape `Loopctl.Workers.WebhookCleanupWorker` uses. A setting that is
  not a positive integer is IGNORED with a warning rather than silently taken (a JSON
  `"30"` is not 30), and one below a table's floor is raised to the floor: an operator may
  keep more than the default, never less than what is still load-bearing.

  ## Design for the failure (SOUL rule 9)

  - **Where it runs.** One Oban job in the `:cleanup` queue, on whichever node picks it up.
    The candidate TENANT list is one bounded read on `AdminRepo` (`Tenants.list_tenants/1`,
    the same shape `Loopctl.Workers.WebhookCleanupWorker` uses); the trace deletes then run
    on the RLS `Loopctl.Repo` inside `Repo.with_tenant/2` and the delivery deletes on
    `AdminRepo`, each following the isolation its owning module documents. The trace half in
    particular must NOT go on `AdminRepo`: that pool is three connections that
    `ValidateWitnessHeader` reads on every authenticated request, and this is the highest-
    volume table in the system.
  - **Where the state lives.** Nowhere but the rows. There is no cursor, no checkpoint and
    nothing to reconcile: progress IS the deletion, candidates are ordered oldest-first, and
    a pruned row never comes back. Two runs an hour apart resume by re-selecting.
  - **Restart mid-batch.** Every batch is its own transaction, so a node that dies keeps
    each committed batch and loses at most the one in flight. Oban's Lifeline re-runs the
    job; there is nothing to undo.
  - **Retries and running twice.** Deleting a row is idempotent and the count is what the
    database reports, so a second run cannot double-count — it finds fewer rows. Concurrent
    runs take candidates `FOR UPDATE SKIP LOCKED`, so they prune disjoint sets instead of
    one waiting on the other.
  - **A slow connection.** Every batch sets its own `statement_timeout` and `lock_timeout`
    (scoped by `Loopctl.LocalGuc`, so neither leaks past the transaction), and the per-tenant
    budget stops a run that cannot keep up instead of letting it run until something else
    times out. A batch that raises fails the job — visibly, with Oban's retry — rather than
    being swallowed.
  - **Falling behind.** Every run emits `[:loopctl, :delivery_loop, :prune]` per table with
    the rows deleted and how many tenants stopped at their budget, and logs a warning naming
    each. A `tenants_at_budget` that stays non-zero across runs is the signal that the
    hourly cadence or the budget no longer matches the write rate.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  require Logger

  alias Loopctl.Intake
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Tenants
  alias Loopctl.Tenants.Tenant

  @default_trace_retention_days 14

  # Three times GitHub's ~30-day delivery history, so an operator has room to shorten the
  # window without reaching the floor.
  @default_intake_retention_days 90

  # GitHub keeps roughly 30 days of webhook deliveries and "Redeliver" reuses the delivery
  # id, so a row younger than this may still be replayed and is still evidence.
  @min_intake_retention_days 30

  # Observability only; one lost day of trace is not a correctness failure.
  @min_trace_retention_days 1

  @telemetry [:loopctl, :delivery_loop, :prune]

  @doc "Default trace-event retention, in days, when a tenant sets none."
  @spec default_trace_retention_days() :: pos_integer()
  def default_trace_retention_days, do: @default_trace_retention_days

  @doc "Default intake-delivery retention, in days, when a tenant sets none."
  @spec default_intake_retention_days() :: pos_integer()
  def default_intake_retention_days, do: @default_intake_retention_days

  @doc """
  The floor under any tenant's intake-delivery retention: below it a redelivery GitHub can
  still send would be applied twice.
  """
  @spec min_intake_retention_days() :: pos_integer()
  def min_intake_retention_days, do: @min_intake_retention_days

  @doc "The floor under any tenant's trace retention."
  @spec min_trace_retention_days() :: pos_integer()
  def min_trace_retention_days, do: @min_trace_retention_days

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    started = System.monotonic_time(:millisecond)
    now = DateTime.utc_now()
    {:ok, tenants} = Tenants.list_tenants()

    totals =
      Enum.reduce(tenants, %{trace: empty(), intake: empty()}, fn tenant, acc ->
        %{trace: trace, intake: intake} = prune_tenant(tenant, now)
        %{trace: merge(acc.trace, trace), intake: merge(acc.intake, intake)}
      end)

    duration = System.monotonic_time(:millisecond) - started

    report("runner_trace_events", totals.trace, length(tenants), duration)
    report("intake_deliveries", totals.intake, length(tenants), duration)
    log_run(totals, length(tenants))

    :ok
  end

  @doc """
  Prunes both tables for ONE tenant, as of `now`, and returns
  `%{trace: result, intake: result}` (each `%{deleted: n, budget_exhausted: bool}`).

  Takes the tenant STRUCT, not an id: the windows come from `tenant.settings`, and nothing
  here needs the row re-read. `perform/1` folds this over every tenant; an operator draining
  one tenant's backlog can call it with a larger `:budget` without waiting for the hour.
  """
  @spec prune_tenant(Tenant.t(), DateTime.t(), keyword()) :: %{
          trace: %{deleted: non_neg_integer(), budget_exhausted: boolean()},
          intake: %{deleted: non_neg_integer(), budget_exhausted: boolean()}
        }
  def prune_tenant(%Tenant{} = tenant, %DateTime{} = now, opts \\ []) do
    %{trace: prune_trace(tenant, now, opts), intake: prune_intake(tenant, now, opts)}
  end

  defp prune_trace(tenant, now, opts) do
    days =
      retention_days(
        tenant,
        "runner_trace_retention_days",
        @default_trace_retention_days,
        @min_trace_retention_days
      )

    result = DispatchLedger.prune_trace_events(tenant.id, cutoff(now, days), opts)
    log_tenant("runner_trace_events", tenant, days, result)
    result
  end

  defp prune_intake(tenant, now, opts) do
    days =
      retention_days(
        tenant,
        "intake_delivery_retention_days",
        @default_intake_retention_days,
        @min_intake_retention_days
      )

    result = Intake.prune_deliveries(tenant.id, cutoff(now, days), opts)
    log_tenant("intake_deliveries", tenant, days, result)
    result
  end

  # An explicit timestamp, never a whole-day boundary: "older than N days" computed as a date
  # leaves the newest day of rows behind on every run, which reads as the pruner keeping up
  # while a day's worth accumulates for ever.
  defp cutoff(now, days), do: DateTime.add(now, -days * 86_400, :second)

  # A setting below the floor is RAISED to the floor rather than refused: keeping more than
  # the floor is always allowed, keeping less is what the floor exists to prevent. Anything
  # that is not a positive integer is not a retention window at all — a JSON `"30"` is a
  # string — so the default applies and the operator is told, because a setting that silently
  # does nothing is worse than one that is rejected.
  defp retention_days(tenant, key, default, floor) do
    case Tenants.get_tenant_settings(tenant, key, default) do
      days when is_integer(days) and days >= floor ->
        days

      days when is_integer(days) and days > 0 ->
        floor

      other ->
        Logger.warning(
          "DeliveryLoopPruneWorker: ignoring #{key}=#{inspect(other)} for tenant " <>
            "#{tenant.id} — expected a positive integer; using the default #{default}",
          tenant_id: tenant.id
        )

        default
    end
  end

  defp empty, do: %{deleted: 0, at_budget: 0}

  defp merge(acc, %{deleted: deleted, budget_exhausted: exhausted?}) do
    %{
      acc
      | deleted: acc.deleted + deleted,
        at_budget: acc.at_budget + if(exhausted?, do: 1, else: 0)
    }
  end

  defp report(table, %{deleted: deleted, at_budget: at_budget}, tenants, duration) do
    :telemetry.execute(
      @telemetry,
      %{deleted: deleted, tenants_at_budget: at_budget, tenants: tenants, duration_ms: duration},
      %{table: table}
    )
  end

  defp log_tenant(_table, _tenant, _days, %{deleted: 0, budget_exhausted: false}), do: :ok

  defp log_tenant(table, tenant, days, %{deleted: deleted, budget_exhausted: true}) do
    Logger.warning(
      "DeliveryLoopPruneWorker: budget reached, rows left: table=#{table} " <>
        "tenant_id=#{tenant.id} deleted=#{deleted} retention_days=#{days}",
      tenant_id: tenant.id
    )
  end

  defp log_tenant(table, tenant, days, %{deleted: deleted}) do
    Logger.info(
      "DeliveryLoopPruneWorker: pruned: table=#{table} tenant_id=#{tenant.id} " <>
        "deleted=#{deleted} retention_days=#{days}",
      tenant_id: tenant.id
    )
  end

  defp log_run(%{trace: trace, intake: intake}, tenants) do
    if trace.deleted > 0 or intake.deleted > 0 or trace.at_budget > 0 or intake.at_budget > 0 do
      Logger.info(
        "DeliveryLoopPruneWorker: tenants=#{tenants} " <>
          "runner_trace_events=#{trace.deleted} (at_budget=#{trace.at_budget}) " <>
          "intake_deliveries=#{intake.deleted} (at_budget=#{intake.at_budget})"
      )
    end

    :ok
  end
end
