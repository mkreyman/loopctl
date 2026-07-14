defmodule Loopctl.Oban.FairShare do
  @moduledoc """
  Per-tenant in-flight fair-share gate for the contended Oban queues (US-36.2, #351).

  Stock Oban 2.19's Basic engine is plain FIFO per queue — no partitioning, no
  per-args concurrency limits (those are Smart-engine only, deferred to Epic 38).
  One tenant's bulk burst (a 50-item ingest fans out to hundreds of embedding +
  linking jobs, all one `tenant_id`, inserted contiguously) therefore sits at the
  head of a shared queue and starves every other tenant indefinitely.

  The Basic-engine-idiomatic, LOSS-FREE fix is COOPERATIVE YIELDING: at the START
  of `perform/1` a contended-queue worker asks `gate/2` whether its tenant already
  occupies at or above its fair share of that queue's EXECUTING slots. If so, the
  worker returns `{:snooze, n}` — Oban reschedules the job WITHOUT consuming an
  attempt and NEVER drops it, freeing the slot for a waiting tenant. Fairness thus
  degrades to LATENCY, never to loss/correctness.

  ## Fair share is a TARGET, not an invariant

  The count is inherently racy (it reflects a moment that has already passed by the
  time the gate acts — see the wiki finding "Race condition: querying Oban job count
  from inside a running job gives a stale result"). That is ACCEPTABLE: the goal is
  to stop MONOPOLIZATION, not to enforce an exact slot count. A byzantine tenant can
  still get service — just not all of it.

  ## Never wedges a queue

  The cap (`Loopctl.ObanConfig.tenant_fair_share_cap/1`) is ALWAYS `>= 1`, so a
  tenant may always hold at least one slot and the gate can never drive every job to
  snooze forever. The gate additionally FAILS OPEN: if the count query errors or
  times out, `over_fair_share?/3` returns `false` (the job proceeds) rather than
  blocking — an unmeasurable count must never stall work.

  ## The gate MUST exclude the running job from its own count

  Under Oban's Basic engine the fetched job is committed to `state = 'executing'`
  INSIDE `fetch_jobs`' `Repo.transaction` BEFORE it is dispatched to the worker
  Task — the same reason Lifeline can find orphaned `executing` rows after a node
  dies. So a naive `count(... state='executing' AND tenant ...)` run from inside
  `perform/1` COUNTS THE RUNNING JOB ITSELF. That is catastrophic:

    * Effective per-tenant concurrency becomes `cap - 1`, not `cap` (off-by-one on
      every gated queue: embeddings 3→2, knowledge 2→1).
    * For a queue whose derived cap is 1 (`:ingestion`, width 2 → `ceil(2/2)=1`)
      EVERY job — even a single uncontended one — sees `1 >= 1` and snoozes
      FOREVER: the queue is permanently WEDGED, the exact anti-goal above.

  The gate therefore threads the current `Oban.Job.id` through to the count and
  excludes it (`j.id != ^job_id`), so a lone job sees `others = 0 < cap` and runs.
  The public `executing_count/2` / `in_flight_count/2` helpers (reused by US-36.3's
  `/queue-health` endpoint) are UNSCOPED counts — they intentionally do NOT exclude
  any job; self-exclusion belongs only to the gate's decision path.

  ## The count helper (AC-36.2.1)

  `oban_jobs` is Oban-owned, schemaless, has NO RLS and is NOT tenant-scoped by
  schema. We query it as a string source through `Loopctl.AdminRepo` (BYPASSRLS),
  scoping by `args->>'tenant_id'` — the same precedent as
  `Loopctl.Knowledge.count_pending_extractions/1`. `tenant_id` is stringified for the
  text compare. Two counts are exposed:

    * `in_flight_count/2` — the broad 4-state set
      (`available`/`scheduled`/`executing`/`retryable`), the GENERAL helper reused by
      US-36.3's `/queue-health` endpoint.
    * `executing_count/2` — only `executing`, the slot-occupancy the fair-share gate
      decides on (AC-36.2.2).

  ### Cost / index justification

  The query filters `queue = $1 AND state (= or IN) ... AND args->>'tenant_id' = $2`.
  Oban's own default index `oban_jobs_state_queue_priority_scheduled_at_id_index`
  leads with `(state, queue)`, so the planner Index-Scans exactly the small
  NON-TERMINAL population for that `(state, queue)` and applies `args->>'tenant_id'`
  as a cheap filter over it — the enormous `completed`/`discarded` backlog (pruned
  after 7 days, but still the bulk of the table) is never touched because `state` is
  the leading column. Measured on the dev DB (~18k jobs): the `executing` count is
  `Index Scan … Index Cond ((state,queue)) … shared hit=3`, ~0.05 ms; the 4-state
  count is `shared hit=12`, ~0.05 ms. NO new index is warranted — a
  `(args->>'tenant_id', queue, state)` index would be strictly worse, leading with
  the high-cardinality tenant expression and folding the whole completed backlog
  under each tenant. Each count runs under a per-query `SET LOCAL statement_timeout`
  (pgbouncer-safe — a startup `:parameters` timeout is rejected by Fly's pgbouncer
  with 08P01; see `Loopctl.HeavyRead`).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.ObanConfig

  # The four non-terminal Oban states — the GENERAL in-flight set (AC-36.2.1),
  # shared with US-36.3's queue-health endpoint.
  @non_terminal_states ~w(available scheduled executing retryable)

  # Bound the read on the hot, Oban-owned oban_jobs table. Generous vs the measured
  # sub-ms cost, but a hard ceiling so a pathological plan can never pin a slot on
  # the fairness check itself.
  @count_statement_timeout_ms 2_000

  @doc """
  The fair-share gate a contended-queue worker calls at the TOP of its
  tenant-scoped `perform/1`.

  Pass the current `Oban.Job.id` as `job_id` so the running job is EXCLUDED from its
  own executing-count — otherwise, because the Basic engine commits the job to
  `executing` before dispatching it, a job would count itself and wedge cap=1 queues
  (see the moduledoc). `job_id` may be `nil` (e.g. a bare `perform/1` struct in a
  test) — then nothing is excluded.

  Returns `:ok` to proceed, or `{:snooze, n}` (bounded, jittered seconds) when the
  tenant is at or above its fair share of the queue's EXECUTING slots — the worker
  returns that snooze verbatim, yielding the slot without consuming an attempt.
  """
  @spec gate(binary(), atom(), pos_integer() | nil) :: :ok | {:snooze, pos_integer()}
  def gate(tenant_id, queue, job_id \\ nil) when is_binary(tenant_id) and is_atom(queue) do
    if over_fair_share?(tenant_id, queue, job_id) do
      {:snooze, snooze_seconds()}
    else
      :ok
    end
  end

  @doc """
  True when `tenant_id` already occupies at or above its fair-share cap of `queue`'s
  EXECUTING slots (AC-36.2.2), EXCLUDING the job identified by `job_id` (the running
  job — see the moduledoc). FAILS OPEN (`false`) on any count error/timeout so the
  gate can never wedge a queue.
  """
  @spec over_fair_share?(binary(), atom(), pos_integer() | nil) :: boolean()
  def over_fair_share?(tenant_id, queue, job_id \\ nil)
      when is_binary(tenant_id) and is_atom(queue) do
    cap = ObanConfig.tenant_fair_share_cap(queue)
    executing_count_excluding(tenant_id, queue, job_id) >= cap
  rescue
    e ->
      # Best-effort fairness: an unmeasurable count must NEVER block a job (SECURITY
      # note — the gate must not be able to wedge a queue). Proceed and log.
      Logger.warning(
        "FairShare gate failed open on queue=#{queue} tenant=#{tenant_id}: " <>
          Exception.message(e)
      )

      false
  end

  @doc """
  Broad in-flight count for `tenant_id` on `queue` across the four non-terminal
  states (`available`/`scheduled`/`executing`/`retryable`) — AC-36.2.1. This is the
  GENERAL helper US-36.3's endpoint reuses.
  """
  @spec in_flight_count(binary(), atom() | binary()) :: non_neg_integer()
  def in_flight_count(tenant_id, queue) do
    count(tenant_id, queue, @non_terminal_states, nil)
  end

  @doc """
  Count of `tenant_id`'s currently-EXECUTING jobs on `queue` (AC-36.2.2) — the
  UNSCOPED slot-occupancy (counts every executing job, including any running caller).
  US-36.3's `/queue-health` endpoint reuses this. The gate's decision path uses the
  self-excluding count instead (see `over_fair_share?/3`).
  """
  @spec executing_count(binary(), atom() | binary()) :: non_neg_integer()
  def executing_count(tenant_id, queue) do
    count(tenant_id, queue, ["executing"], nil)
  end

  # Executing-count for the gate's decision: excludes the running job (`job_id`) so a
  # job never counts itself and wedges a cap=1 queue (see the moduledoc). `job_id` nil
  # excludes nothing.
  defp executing_count_excluding(tenant_id, queue, job_id) do
    count(tenant_id, queue, ["executing"], job_id)
  end

  @doc """
  A bounded, jittered snooze interval in seconds (AC-36.2.5): `base + rand(0..jitter)`
  where both `base` (`> 0`) and `jitter` (`>= 0`) come from `Loopctl.ObanConfig`
  (env-tunable). Jitter avoids a thundering-herd of snoozed jobs re-checking in
  lockstep; the small bound keeps a yielded job from starving.
  """
  @spec snooze_seconds() :: pos_integer()
  def snooze_seconds do
    base = ObanConfig.fair_share_snooze_base_seconds()
    jitter = ObanConfig.fair_share_snooze_jitter_seconds()
    # :rand.uniform(jitter + 1) ∈ 1..jitter+1 → -1 gives 0..jitter (0 when jitter=0).
    base + :rand.uniform(jitter + 1) - 1
  end

  # Tenant-scoped, bounded count over the Oban-owned oban_jobs table via AdminRepo
  # (BYPASSRLS — the table has no RLS), run under a per-query SET LOCAL
  # statement_timeout inside a transaction (pgbouncer-safe). `queue` may be an atom
  # (worker config) or string (raw); oban_jobs.queue is text, so it's stringified.
  defp count(tenant_id, queue, states, exclude_job_id) do
    queue_str = to_string(queue)
    tenant_id_str = to_string(tenant_id)

    base =
      from(j in "oban_jobs",
        where:
          j.queue == ^queue_str and j.state in ^states and
            fragment("? ->> 'tenant_id' = ?", j.args, ^tenant_id_str),
        select: count(j.id)
      )

    # Exclude the running job from its own count (the gate's self-exclusion). Under
    # the Basic engine the caller is already `executing` when it reads this, so
    # without `j.id != ^exclude_job_id` a lone job self-counts and wedges cap=1.
    query =
      if is_integer(exclude_job_id) do
        from(j in base, where: j.id != ^exclude_job_id)
      else
        base
      end

    {:ok, result} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!("SET LOCAL statement_timeout = #{@count_statement_timeout_ms}")
        AdminRepo.one(query)
      end)

    result || 0
  end
end
