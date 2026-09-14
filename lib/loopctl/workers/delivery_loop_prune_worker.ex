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
  - **CONTENTION gets ONE immediate retry, on the budget it has LEFT** (`verdict/2`,
    `attempt_prune/5`). A lock wait or a deadlock can be gone in milliseconds; a deterministic
    fault cannot, so after the retry it is counted. The retry runs on `budget - deleted`,
    because re-running a closure with the budget baked in let one tenant and table delete up
    to twice its budget in a run — the second helping against a pool that had just reported
    contention. A CONNECTION-class fault (the pool or backend is gone) gets no in-run retry at
    all: it cannot clear in milliseconds, and `backoff/1` is its retry instead.
  - **A partial failure is `:ok`; only a total one is the job's** (`outcome/2`). One broken
    tenant returning an error undid the isolation above — the job discarded, the whole fan-out
    re-ran three times an hour re-pruning every healthy tenant, and the exceptions biased the
    fleet-wide discard rate. `tenants_failed` carries a partial failure instead.
  - **The run has a wall clock** (`@run_deadline_ms`, checked between tenants). Past it the
    run stops and reports `tenants_skipped` rather than holding a `:cleanup` slot for hours.
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

  use Oban.Worker, queue: :cleanup, max_attempts: 5

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

  # A CONTENTION fault gets ONE immediate retry inside the run; the second failure is the
  # bound (`verdict/2`). A connection-class fault gets none — `backoff/1` is its retry.
  @attempts_per_unit 2

  # The wall clock one RUN may spend, checked between tenants. The cron is hourly, so ten
  # minutes leaves the next run its whole slot: a run that would otherwise hold a `:cleanup`
  # slot for hours stops instead and says how many tenants it did not reach. Every tenant is
  # separately bounded by its budget and batch, so this only binds a FLEET large enough that
  # bounded work still adds up.
  @run_deadline_ms 10 * 60 * 1_000

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
  Minutes, not seconds, and rising: 1, 2, 3, 4 minutes across `max_attempts`.

  The job only reports an error when NOTHING succeeded (`outcome/2`), and the ordinary cause
  of that is the database being briefly unreachable — a rolling deploy above all. Oban's
  default backoff would have exhausted every attempt inside about a minute, well short of one,
  so a routine deploy discarded the run. Nothing here is latency-sensitive: the next scheduled
  run is an hour out, so waiting minutes costs nothing and buys surviving the deploy.
  """
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 60 * attempt

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
    deadline = started + Keyword.get(opts, :deadline_ms, @run_deadline_ms)
    empty_totals = %{trace: empty(), intake: empty(), skipped: 0}

    totals =
      tenants
      |> Enum.with_index()
      |> Enum.reduce_while(empty_totals, fn {tenant, index}, acc ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, %{acc | skipped: length(tenants) - index}}
        else
          %{trace: trace, intake: intake} = prune_tenant(tenant, now, opts)
          {:cont, %{acc | trace: merge(acc.trace, trace), intake: merge(acc.intake, intake)}}
        end
      end)

    duration = System.monotonic_time(:millisecond) - started
    processed = length(tenants) - totals.skipped

    report("runner_trace_events", totals.trace, processed, totals.skipped, duration)
    report("intake_deliveries", totals.intake, processed, totals.skipped, duration)
    log_run(totals, processed)

    outcome(totals, processed * 2)
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
  Resolves the options ONE half runs with: the caller's, each capped at that half's own
  constant, with both always present.

  **Every half is capped, in BOTH directions of the argument.** Validating an arg's TYPE was
  only half the job: `%{"batch_size" => 20_000}` is a perfectly good positive integer, and
  uncapped it gave the trace half one `SELECT FOR UPDATE` of 20,000 rows and one `DELETE` of
  20,000 in a single transaction — verbatim the thing the batch exists to prevent. Worse, it
  is self-perpetuating: a batch that size usually exceeds `statement_timeout`, rolls back, is
  classified as contention, retries identically and fails, so that tenant prunes NOTHING,
  hourly, for ever. A budget override was the same gap on the other axis.

  So the knob only ever makes a run SMALLER. To drain a backlog faster, enqueue more runs —
  each one bounded — rather than one unbounded one.

  Both keys are always set because the retry needs the effective budget to subtract what the
  first attempt already deleted (`attempt_prune/5`). A non-number passes through untouched:
  `prune_tenant/3`'s opts are an internal contract, and only `prune_opts/1` faces an operator.
  """
  @spec half_opts(keyword(), pos_integer(), pos_integer()) :: keyword()
  def half_opts(opts, max_batch_size, max_budget) do
    [
      batch_size: cap(Keyword.get(opts, :batch_size, max_batch_size), max_batch_size),
      budget: cap(Keyword.get(opts, :budget, max_budget), max_budget)
    ] ++ Keyword.drop(opts, [:batch_size, :budget])
  end

  @doc "`half_opts/3` for the trace half, against `Loopctl.Runners.DispatchLedger`'s constants."
  @spec trace_opts(keyword()) :: keyword()
  def trace_opts(opts) do
    half_opts(opts, DispatchLedger.prune_batch_size(), DispatchLedger.prune_budget())
  end

  @doc """
  `half_opts/3` for the intake half, against `Loopctl.Intake`'s constants — which are an order
  of magnitude smaller because that half runs on `AdminRepo`, whose three connections carry
  request traffic on every authenticated call.
  """
  @spec intake_opts(keyword()) :: keyword()
  def intake_opts(opts) do
    half_opts(opts, Intake.prune_batch_size(), Intake.prune_budget())
  end

  defp cap(value, ceiling) when is_number(value), do: min(value, ceiling)
  defp cap(value, _ceiling), do: value

  # A PARTIAL failure is `:ok`, and that is deliberate. Returning an error for one broken
  # tenant undid the isolation `attempt_prune/5` provides: the job discarded, Oban re-ran the
  # WHOLE fan-out three times an hour, every healthy tenant was re-pruned with a fresh full
  # budget each attempt, and the exception events biased the fleet-wide discard rate
  # `Loopctl.Telemetry.ScaleAlerts` watches — where a discard means something else entirely.
  # `tenants_failed`, the per-table measurement, is what carries a partial failure, which is
  # exactly what it was added for; the moduledoc says to alert on it.
  #
  # NOTHING succeeding is a different claim — an outage rather than a broken tenant — and that
  # one IS the job's to report, so Oban's backoff (`backoff/1`) becomes its retry. That is also
  # the path a rolling deploy takes, which is why the backoff is measured in minutes.
  defp outcome(%{trace: trace, intake: intake}, units) do
    failed = trace.failed + intake.failed

    cond do
      failed == 0 ->
        :ok

      failed < units ->
        :ok

      true ->
        {:error,
         "DeliveryLoopPruneWorker: every one of #{units} tenant/table prune(s) failed; " <>
           "see the preceding log lines for the tenant ids and reasons"}
    end
  end

  @doc """
  Prunes both tables for ONE tenant, as of `now`, and returns
  `%{trace: result, intake: result}` (each `%{deleted: n, budget_exhausted: bool}`).

  Takes the tenant STRUCT, not an id: the windows come from `tenant.settings`, and nothing
  here needs the row re-read. `perform/1` folds this over every tenant; an operator can call
  it for one tenant without waiting for the hour.

  `opts` are an internal contract and each half caps them at its own constants
  (`trace_opts/1`, `intake_opts/1`), so they can only make a run SMALLER.
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

    cutoff = cutoff(now, days)

    attempt_prune("runner_trace_events", tenant, days, trace_opts(opts), fn attempt_opts ->
      DispatchLedger.prune_trace_events(tenant.id, cutoff, attempt_opts)
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

    cutoff = cutoff(now, days)

    attempt_prune("intake_deliveries", tenant, days, intake_opts(opts), fn attempt_opts ->
      Intake.prune_deliveries(tenant.id, cutoff, attempt_opts)
    end)
  end

  # ONE tenant's ONE table. A raise or an exit here is contained to this call: the fold moves
  # on to the next tenant, and — because `Tenants.list_tenants/1` orders by name — it is
  # otherwise deterministically the SAME later tenants that never get pruned, hourly and for
  # ever. Containing it is also what keeps the run's telemetry meaningful: `report/4` runs
  # after the fold, so an escaping error suppressed `tenants_at_budget` on exactly the runs
  # where it was non-zero.
  @doc """
  Runs ONE tenant's ONE table under the retry rule, and returns a `t:half_result/0` instead of
  raising.

  `fun` receives the OPTS it should run with, which is the whole reason it takes them: the
  retry passes the budget MINUS what the first attempt already deleted. Re-invoking a closure
  that had the budget baked in let one tenant and table delete up to twice its budget in a
  single run — the second helping against a pool that had just reported contention.

  Public so the retry path can be driven by an injected prune. A real contention fault needs a
  second connection holding a lock, and the SQL sandbox gives a test one per repo (see
  `verdict/2`), so this is the only way the accumulation and the remaining-budget arithmetic
  can be made to go red.
  """
  @spec attempt_prune(String.t(), Tenant.t(), pos_integer(), keyword(), (keyword() -> map())) ::
          half_result()
  def attempt_prune(table, tenant, days, opts, fun) do
    try_prune(table, tenant, days, opts, fun, 1, 0)
  end

  defp try_prune(table, tenant, days, opts, fun, attempt, deleted_before) do
    result = safely(fn -> fun.(opts) end)
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
            retry_opts = Keyword.put(opts, :budget, remaining_budget(opts, deleted))
            try_prune(table, tenant, days, retry_opts, fun, attempt + 1, deleted)

          :fail ->
            log_failure(table, tenant, days, error, deleted)
            # `budget_exhausted` comes from the RESULT, never a literal: both prune loops set
            # it conservatively to true when the PROBE faulted, because a probe that could not
            # run cannot say the backlog is empty.
            %{deleted: deleted, budget_exhausted: result.budget_exhausted, failed: 1}
        end
    end
  end

  # What the retry is still allowed to take. `half_opts/3` always sets `:budget`; the `0`
  # default is for a caller that did not, and makes the retry a no-op rather than a fresh
  # helping.
  defp remaining_budget(opts, deleted) do
    max(Keyword.get(opts, :budget, 0) - deleted, 0)
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
  The pure decision behind a failed prune: retry it IMMEDIATELY once inside this run, or give
  up on it.

  Only CONTENTION earns that retry — a lock wait that ran out (55P03), a deadlock Postgres
  broke (40P01), a statement the timeout cancelled (57014), a serialization failure. Those are
  another transaction's doing and can be gone milliseconds later.

  **A CONNECTION-CLASS fault does not** (`DBConnection.ConnectionError`, an exit, 57P01/57P02
  shutdown, 57P03 cannot-connect-now). The backend or the pool is GONE, so an immediate retry
  cannot possibly clear it: it spends the attempt for nothing and brings the failure forward.
  Those wait for `backoff/1` instead, which is measured in minutes precisely so a rolling
  deploy — the ordinary cause — outlasts nothing.

  A contention fault that survives its one retry is treated exactly like any other failure:
  counted, logged, and carried into the run's `tenants_failed`. That bound is the point.
  Classifying a fault "transient" for ever meant a deterministic 15-second timeout retried
  hourly with the job green and every alert metric at zero.

  Public and PURE because neither branch can otherwise be exercised: a lock wait needs a
  second connection, and the SQL sandbox gives a test one per repo. Same reason
  `Loopctl.Repo.assert_not_nested!/2` is public.
  """
  @spec verdict(term(), pos_integer()) :: :retry | :fail
  def verdict(error, attempt) when is_integer(attempt) and attempt > 0 do
    if contention?(error) and attempt < @attempts_per_unit, do: :retry, else: :fail
  end

  defp contention?(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :lock_not_available,
              :deadlock_detected,
              :query_canceled,
              :serialization_failure
            ],
       do: true

  defp contention?(_error), do: false

  @doc """
  Whether a fault is the CONNECTION class — the pool or the backend went away, rather than
  another transaction getting in the way. Named apart from `verdict/2` because the two answer
  different questions: this one decides how a failure is LOGGED, and it is what tells an
  operator an outage from contention.
  """
  @spec connection_fault?(term()) :: boolean()
  def connection_fault?(%DBConnection.ConnectionError{}), do: true
  def connection_fault?({:exit, _reason}), do: true

  def connection_fault?(%Postgrex.Error{postgres: %{code: code}})
      when code in [:admin_shutdown, :crash_shutdown, :cannot_connect_now],
      do: true

  def connection_fault?(_error), do: false

  defp log_retry(table, tenant, error) do
    Logger.warning(
      "DeliveryLoopPruneWorker: transient fault, retrying once: table=#{table} " <>
        "tenant_id=#{tenant.id} error=#{inspect(error)}",
      tenant_id: tenant.id
    )
  end

  defp log_failure(table, tenant, days, error, deleted) do
    class = if connection_fault?(error), do: "connection", else: "other"

    Logger.error(
      "DeliveryLoopPruneWorker: prune failed: table=#{table} tenant_id=#{tenant.id} " <>
        "retention_days=#{days} deleted_before_failure=#{deleted} class=#{class} " <>
        "error=#{inspect(error)}",
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

  defp report(table, totals, tenants, skipped, duration) do
    :telemetry.execute(
      @telemetry,
      %{
        deleted: totals.deleted,
        tenants_at_budget: totals.at_budget,
        tenants_failed: totals.failed,
        tenants_skipped: skipped,
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

  defp log_run(%{trace: trace, intake: intake, skipped: skipped}, tenants) do
    noteworthy? =
      skipped > 0 or
        Enum.any?([trace, intake], fn t -> t.deleted > 0 or t.at_budget > 0 or t.failed > 0 end)

    if noteworthy? do
      Logger.info(
        "DeliveryLoopPruneWorker: tenants=#{tenants} skipped=#{skipped} " <>
          "runner_trace_events=#{trace.deleted} " <>
          "(at_budget=#{trace.at_budget} failed=#{trace.failed}) " <>
          "intake_deliveries=#{intake.deleted} " <>
          "(at_budget=#{intake.at_budget} failed=#{intake.failed})"
      )
    end

    if skipped > 0 do
      Logger.warning(
        "DeliveryLoopPruneWorker: wall clock reached, #{skipped} tenant(s) not reached this " <>
          "run; they are first on the next one only if the run before them shortens — check " <>
          "tenants_at_budget"
      )
    end

    :ok
  end
end
