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
  shape `Loopctl.Workers.WebhookCleanupWorker` uses. A setting above
  `max_retention_days/0` is capped there — the value a slip most plausibly produces is a DATE
  pasted where a day count belongs, which puts the cutoff outside `timestamptz` range and
  makes Postgres refuse the query. A setting that is
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
    volume table in the system. The delivery half stays there — `Loopctl.Intake` resolves a
    tenant FROM a source id and is `AdminRepo` throughout — and pays for it with numbers an
    order of magnitude smaller (`Intake.prune_batch_size/0`, `Intake.prune_budget/0`): a batch
    is its own short transaction that returns the connection between batches, and the budget
    caps a tenant at ten of them per run. Deliveries arrive at webhook rate, so that still
    reclaims far more per day than any repository produces.
  - **One tenant never stops the rest.** Each tenant's each table is guarded: a fault is
    logged with the tenant id, counted, and the fold continues, carrying the rows the batches
    BEFORE it already committed. `list_tenants/1` orders by name, so without this it is
    deterministically the same later tenants that are never pruned.
  - **A fault gets ONE immediate retry, and then it is a failure** (`verdict/2`). A genuine
    blip — a lock wait, a deadlock — clears on that retry. A DETERMINISTIC fault does not, and
    after the retry it is counted and the job reports an error. That bound is the point:
    treating a 15-second statement timeout a query has outgrown as "transient" for ever meant
    it retried hourly with the job green and every alert metric at zero. Oban retries the job,
    so a real blip still resolves without anyone being told; a persistent one exhausts the
    attempts and shows up as a discarded job.
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
  - **Falling behind, and the two signals that say so.** Every run emits
    `[:loopctl, :delivery_loop, :prune]` PER TABLE with `deleted`, `tenants_at_budget`,
    `tenants_failed`, `tenants` and `duration_ms`.

    **ALERT ON BOTH.** `tenants_at_budget` staying non-zero across runs means the cadence or
    the budget no longer matches the write rate — and it is measured rather than inferred,
    since a tenant landing exactly on its budget is probed for a further candidate before it
    is counted. `tenants_failed` is the other half and it must be alerted on separately,
    because a run where EVERY tenant failed emits the profile of an idle healthy fleet on the
    first signal alone: nothing deleted, nobody at budget. What distinguishes them is
    `tenants_failed` and the job's own error, so neither can be the only thing watched.
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

  # Ten years. A window is a DAY COUNT, and the value a slip most plausibly produces is a
  # DATE pasted where a count belongs (20260918 days is ~55,000 years, which puts `cutoff/2`
  # outside `timestamptz` range and makes Postgres refuse the query). Keeping more than this
  # is indistinguishable from keeping everything, so the ceiling costs an operator nothing.
  @max_retention_days 3650

  @telemetry [:loopctl, :delivery_loop, :prune]

  # A transient fault gets ONE immediate retry inside the run; the second failure is the
  # bound (`verdict/2`).
  @attempts_per_unit 2

  @typedoc """
  One tenant's outcome for ONE table. `deleted` is what was COMMITTED, including by the
  batches before a fault; `failed` marks a prune that did not finish even after its retry.
  """
  @type half_result :: %{
          deleted: non_neg_integer(),
          budget_exhausted: boolean(),
          failed: 0 | 1
        }

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

  @doc "The ceiling over any tenant's retention window, whichever table."
  @spec max_retention_days() :: pos_integer()
  def max_retention_days, do: @max_retention_days

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    {:ok, tenants} = Tenants.list_tenants()

    run(tenants, DateTime.utc_now(), prune_opts(job.args))
  end

  @doc """
  The whole run over `tenants`: prune each, report per table, and return the job's verdict.
  `perform/1` is this plus resolving the tenant list and VALIDATING the operator's args.

  Public for the reason `Loopctl.ObanConfig.parse_unparked/1` is: the behaviour that matters
  here — one tenant's failure not stopping the rest, and the run still reporting what it
  managed — needs a prune that FAILS, and `perform/1` cannot be given one now that its args
  are validated. `opts` here are the same internal, unvalidated contract `prune_tenant/3`
  documents.
  """
  @spec run([Tenant.t()], DateTime.t(), keyword()) :: :ok | {:error, String.t()}
  def run(tenants, %DateTime{} = now, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    totals =
      Enum.reduce(tenants, %{trace: empty(), intake: empty()}, fn tenant, acc ->
        %{trace: trace, intake: intake} = prune_tenant(tenant, now, opts)
        %{trace: merge(acc.trace, trace), intake: merge(acc.intake, intake)}
      end)

    duration = System.monotonic_time(:millisecond) - started

    report("runner_trace_events", totals.trace, length(tenants), duration)
    report("intake_deliveries", totals.intake, length(tenants), duration)
    log_run(totals, length(tenants))

    outcome(totals)
  end

  @doc """
  The pure resolution of the operator's job args into prune options.

  The cron entry passes none. `%{"batch_size" => n}` / `%{"budget" => n}` are the manual drain
  knob — one enqueue after a long outage reclaims a backlog faster than twenty-four hourly
  runs. Each must be a POSITIVE INTEGER; anything else is ignored with a warning and the
  default applies.

  That validation is not defensive tidiness, which is why this is public and unit-tested.
  `take = min(batch_size, budget - deleted)` is a TERM comparison, and in Elixir's term order
  a number sorts before every string, atom and map — so `min(nil, 20_000)` is `20_000`, not an
  error. An unvalidated `"1000"` would therefore be refused by nothing: it would silently
  become the WHOLE budget and put 20,000 rows in one DELETE, which is the single thing the
  batch exists to prevent. An unvalidated `budget` is worse still — `deleted >= "1"` is never
  true, so the loop would run to an `ArithmeticError` instead of stopping.
  """
  @spec prune_opts(map()) :: keyword()
  def prune_opts(args) when is_map(args) do
    Enum.flat_map([{"batch_size", :batch_size}, {"budget", :budget}], fn {name, key} ->
      case Map.fetch(args, name) do
        {:ok, value} when is_integer(value) and value > 0 ->
          [{key, value}]

        {:ok, other} ->
          Logger.warning(
            "DeliveryLoopPruneWorker: ignoring #{name}=#{inspect(other)} — expected a " <>
              "positive integer; using the default"
          )

          []

        :error ->
          []
      end
    end)
  end

  def prune_opts(_args), do: []

  @doc """
  Caps prune options at the intake half's own constants.

  That half runs on `AdminRepo`, whose three connections carry request traffic on every
  authenticated call, so `Intake.prune_batch_size/0` and `Intake.prune_budget/0` are a CEILING
  and not merely a default: a drain override raises the TRACE half, and is capped here. A
  smaller value stands — this is a ceiling, not an override — and anything that is not a
  number passes through, since `prune_tenant/3`'s opts are an internal contract and only
  `prune_opts/1` faces an operator.

  Public and pure for the same reason `prune_opts/1` is: the cap only becomes observable in a
  run that crosses the budget, and unit-testing the values costs nothing.
  """
  @spec intake_opts(keyword()) :: keyword()
  def intake_opts(opts) do
    Enum.map(opts, fn
      {:batch_size, value} -> {:batch_size, cap(value, Intake.prune_batch_size())}
      {:budget, value} -> {:budget, cap(value, Intake.prune_budget())}
      other -> other
    end)
  end

  defp cap(value, ceiling) when is_number(value), do: min(value, ceiling)
  defp cap(value, _ceiling), do: value

  # A tenant whose prune could not be completed never stops the fold — but it never leaves the
  # job reading green either. A transient fault has ALREADY had its immediate retry by the
  # time it is counted here (`verdict/2`), so anything that reaches this point is either
  # deterministic or a database that stayed unhappy across two attempts, and both are things
  # an operator has to see. Oban retries the job; a real blip clears on that retry, and a
  # persistent fault exhausts the attempts and shows up as a discarded job.
  defp outcome(%{trace: trace, intake: intake}) do
    case trace.failed + intake.failed do
      0 ->
        :ok

      n ->
        {:error,
         "DeliveryLoopPruneWorker: #{n} tenant/table prune(s) failed after their retry; " <>
           "see the preceding log lines for the tenant ids and reasons"}
    end
  end

  @doc """
  Prunes both tables for ONE tenant, as of `now`, and returns
  `%{trace: result, intake: result}` (each `%{deleted: n, budget_exhausted: bool}`).

  Takes the tenant STRUCT, not an id: the windows come from `tenant.settings`, and nothing
  here needs the row re-read. `perform/1` folds this over every tenant; an operator draining
  one tenant's backlog can call it with a larger `:budget` without waiting for the hour.
  """
  @spec prune_tenant(Tenant.t(), DateTime.t(), keyword()) :: %{
          trace: half_result(),
          intake: half_result()
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

    guarded("runner_trace_events", tenant, days, fn ->
      DispatchLedger.prune_trace_events(tenant.id, cutoff(now, days), opts)
    end)
  end

  defp prune_intake(tenant, now, opts) do
    days =
      retention_days(
        tenant,
        "intake_delivery_retention_days",
        @default_intake_retention_days,
        @min_intake_retention_days
      )

    capped = intake_opts(opts)

    guarded("intake_deliveries", tenant, days, fn ->
      Intake.prune_deliveries(tenant.id, cutoff(now, days), capped)
    end)
  end

  # ONE tenant's ONE table. A raise or an exit here is contained to this call: the fold moves
  # on to the next tenant, and — because `Tenants.list_tenants/1` orders by name — it is
  # otherwise deterministically the SAME later tenants that never get pruned, hourly and for
  # ever. Containing it is also what keeps the run's telemetry meaningful: `report/4` runs
  # after the fold, so an escaping error suppressed `tenants_at_budget` on exactly the runs
  # where it was non-zero.
  defp guarded(table, tenant, days, fun), do: try_prune(table, tenant, days, fun, 1, 0)

  defp try_prune(table, tenant, days, fun, attempt, deleted_before) do
    result = safely(fun)
    deleted = deleted_before + result.deleted

    case result.error do
      nil ->
        outcome = %{deleted: deleted, budget_exhausted: result.budget_exhausted}
        log_tenant(table, tenant, days, outcome)
        Map.put(outcome, :failed, 0)

      error ->
        case verdict(error, attempt) do
          :retry ->
            log_retry(table, tenant, error)
            try_prune(table, tenant, days, fun, attempt + 1, deleted)

          :fail ->
            log_failure(table, tenant, days, error, deleted)
            %{deleted: deleted, budget_exhausted: false, failed: 1}
        end
    end
  end

  # The prune functions report their own faults (with the count they got to), so this is the
  # BACKSTOP for anything they did not catch — including an exit, which is how a pool that is
  # down or wedged fails.
  defp safely(fun) do
    fun.()
  rescue
    error -> %{deleted: 0, budget_exhausted: false, error: error}
  catch
    :exit, reason -> %{deleted: 0, budget_exhausted: false, error: {:exit, reason}}
  end

  @doc """
  The pure decision behind a failed prune: retry it once inside this run, or give up on it.

  A TRANSIENT database fault — a lock wait that ran out (55P03), a deadlock Postgres broke
  (40P01), a statement the timeout cancelled (57014), a serialization failure, a connection
  that went away — is retried IMMEDIATELY, once. A genuine blip clears on that retry; a
  DETERMINISTIC fault (the 15-second timeout a query has outgrown) does not, and after the
  retry it is treated exactly like a non-transient error: counted, logged, and reported by the
  job. That bound is the point. Classifying such a fault "transient" for ever meant it retried
  hourly with the job green and every alert metric at zero.

  Public and PURE because the branch a real lock timeout takes cannot otherwise be exercised:
  a lock wait needs a second connection, and the SQL sandbox gives a test one per repo. Same
  reason `Loopctl.Repo.assert_not_nested!/2` is public.
  """
  @spec verdict(term(), pos_integer()) :: :retry | :fail
  def verdict(error, attempt) when is_integer(attempt) and attempt > 0 do
    if transient?(error) and attempt < @attempts_per_unit, do: :retry, else: :fail
  end

  defp transient?(%DBConnection.ConnectionError{}), do: true
  defp transient?({:exit, _reason}), do: true

  defp transient?(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :lock_not_available,
              :deadlock_detected,
              :query_canceled,
              :serialization_failure,
              :admin_shutdown,
              :crash_shutdown,
              :cannot_connect_now
            ],
       do: true

  defp transient?(_error), do: false

  defp log_retry(table, tenant, error) do
    Logger.warning(
      "DeliveryLoopPruneWorker: transient fault, retrying once: table=#{table} " <>
        "tenant_id=#{tenant.id} error=#{inspect(error)}",
      tenant_id: tenant.id
    )
  end

  defp log_failure(table, tenant, days, error, deleted) do
    Logger.error(
      "DeliveryLoopPruneWorker: prune failed: table=#{table} tenant_id=#{tenant.id} " <>
        "retention_days=#{days} deleted_before_failure=#{deleted} error=#{inspect(error)}",
      tenant_id: tenant.id
    )
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
      days when is_integer(days) and days > @max_retention_days ->
        Logger.warning(
          "DeliveryLoopPruneWorker: #{key}=#{days} for tenant #{tenant.id} exceeds the " <>
            "#{@max_retention_days}-day ceiling; using the ceiling",
          tenant_id: tenant.id
        )

        @max_retention_days

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

  defp empty, do: %{deleted: 0, at_budget: 0, failed: 0}

  defp merge(acc, %{deleted: deleted, budget_exhausted: exhausted?} = half) do
    %{
      acc
      | deleted: acc.deleted + deleted,
        at_budget: acc.at_budget + if(exhausted?, do: 1, else: 0),
        failed: acc.failed + half.failed
    }
  end

  defp report(table, totals, tenants, duration) do
    :telemetry.execute(
      @telemetry,
      %{
        deleted: totals.deleted,
        tenants_at_budget: totals.at_budget,
        tenants_failed: totals.failed,
        tenants: tenants,
        duration_ms: duration
      },
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
    noteworthy? =
      Enum.any?([trace, intake], fn t -> t.deleted > 0 or t.at_budget > 0 or t.failed > 0 end)

    if noteworthy? do
      Logger.info(
        "DeliveryLoopPruneWorker: tenants=#{tenants} " <>
          "runner_trace_events=#{trace.deleted} " <>
          "(at_budget=#{trace.at_budget} failed=#{trace.failed}) " <>
          "intake_deliveries=#{intake.deleted} " <>
          "(at_budget=#{intake.at_budget} failed=#{intake.failed})"
      )
    end

    :ok
  end
end
