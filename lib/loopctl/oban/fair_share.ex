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

  ## Never wedges a queue — and never fails open on a bad CAP

  The cap (`Loopctl.ObanConfig.tenant_fair_share_cap/1`) is ALWAYS `>= 1`, so a
  tenant may always hold at least one slot and (with the rank decision below) the
  gate can never drive every job to snooze forever — even at jitter=0. The gate
  FAILS OPEN on the COUNT only: if the executing-count query errors or times out,
  `over_fair_share?/3` returns `false` (the job proceeds) rather than blocking — an
  unmeasurable count must never stall work.

  The CAP, by contrast, FAILS LOUD. It is read in `over_fair_share?/3` OUTSIDE the
  count's rescue (in `over_cap?/4`), so a malformed `OBAN_TENANT_FAIRSHARE_<QUEUE>`
  crashes the job (visible, like a malformed snooze knob) instead of being swallowed
  into a silent fail-open that would DISABLE fairness during the very incident an
  operator is tuning. `Loopctl.ObanConfig.fair_share_config/0` additionally validates
  every fair-share knob at BOOT (invoked from `config/runtime.exs`), so a typo aborts
  the node like `OBAN_QUEUE_*` — it never even reaches a running gate.

  ## Rank-based decision — deterministic, no co-fetch livelock

  Under Oban's Basic engine the fetched jobs are committed to `state = 'executing'`
  INSIDE `fetch_jobs`' `Repo.transaction` BEFORE they are dispatched to worker Tasks
  (the same reason Lifeline finds orphaned `executing` rows after a node dies). So a
  whole `width`-sized fetch — and under the story's one-tenant bulk fan-out, ALL of
  one tenant's co-fetched jobs — are already `executing` when each `perform/1` runs
  its gate.

  A naive "count OTHER executing peers `>= cap`" decision MISBEHAVES on that co-fetch:
  every co-fetched same-tenant job sees the others, so on a cap=1 queue BOTH see
  `1 >= 1` and BOTH snooze — both slots idle. Under the default jitter that thrashes
  and self-heals; at the PERMITTED jitter=0 the two stay lockstep, are co-fetched
  every cycle, and NEVER complete — a permanent livelock that falsifies the "never
  snooze forever" invariant.

  The gate therefore decides by RANK, not by a raw peer count: a job snoozes only if
  it is NOT among the lowest-`cap` executing job ids for its `(tenant, queue)` — i.e.
  `cap` or more of the tenant's OTHER executing jobs have a strictly LOWER id
  (`count(... state='executing' AND tenant AND j.id < ^job_id) >= cap`). This:

    * EXCLUDES the running job from its own count for free (`id < job_id` can never
      count `id == job_id`), so a lone job (`rank 0`) always runs — cap=1 queues
      never wedge, and gated queues give the full `cap`, not `cap - 1` (no off-by-one:
      embeddings stays 3, knowledge 2).
    * BREAKS the co-fetch symmetry DETERMINISTICALLY: of M co-fetched same-tenant
      jobs, exactly the lowest `cap` by id proceed and the rest snooze — regardless of
      which `perform/1` reads first, and regardless of jitter. No "all snooze" outcome
      exists, so jitter=0 is SAFE and the "never snooze forever" invariant HOLDS: the
      lowest-id executing job for a tenant always has rank 0 → runs → completes, then
      the next, so every job drains in id (≈ FIFO) order and none starves.

  The public `executing_count/2` / `in_flight_count/2` / `in_flight_ingestion_backlog/1`
  helpers (the last is consulted by US-36.3's batch-ingest backlog admission gate — see
  below) are UNSCOPED counts — they intentionally do NOT apply the
  rank predicate; `id < job_id` belongs only to the gate's decision path. `job_id`
  may be `nil` (a bare `perform/1` struct in a test, off the real dispatch path) —
  then the gate falls back to the plain unscoped executing count `>= cap`.

  ## The count helper (AC-36.2.1)

  `oban_jobs` is Oban-owned, schemaless, has NO RLS and is NOT tenant-scoped by
  schema. We query it as a string source through `Loopctl.AdminRepo` (BYPASSRLS),
  scoping by `args->>'tenant_id'` — the same precedent as
  `Loopctl.Knowledge.count_pending_extractions/1`. `tenant_id` is stringified for the
  text compare. Two counts are exposed:

    * `in_flight_count/2` — the broad 4-state set
      (`available`/`scheduled`/`executing`/`retryable`) scoped by `queue` — the
      GENERAL fair-share helper (AC-36.2.1).
    * `in_flight_ingestion_backlog/1` — the SAME broad 4-state set but scoped by
      `worker = ContentIngestionWorker` (the sole worker on the `:ingestion` queue),
      the count US-36.3's batch-ingest backlog admission gate consults (the 429
      backpressure check in `LoopctlWeb.KnowledgeIngestionController`). Filtering by
      `worker` rather than `queue` lets the count ride the partial index
      `oban_jobs_ingestion_tenant_idx` — see "Cost / index justification".
    * `executing_count/2` — only `executing`, the slot-occupancy the fair-share gate
      decides on (AC-36.2.2).

  ### Cost / index justification

  Two count SHAPES with two DIFFERENT cost profiles, because US-36.2 and US-36.3 scope
  the count differently:

  **QUEUE-scoped (`in_flight_count/2`, `executing_count/2` — the fair-share gate).**
  Filters `queue = $1 AND state (= or IN) ... AND args->>'tenant_id' = $2`. Oban's own
  default index `oban_jobs_state_queue_priority_scheduled_at_id_index` leads with
  `(state, queue)`, so the planner Index-Scans exactly the NON-TERMINAL population for
  that `(state, queue)` and applies `args->>'tenant_id'` as a filter over it. The cost
  is O(non-terminal rows on that `(state, queue)`) — NOT reduced by the tenant filter
  under a single-tenant flood — but HARD-BOUNDED by the 2 s statement_timeout. Measured:
  ~0.05 ms benign (~18k terminal/pruned jobs); ~3.5 ms at a synthesised 10k-non-terminal
  `:embeddings` flood (`Index Scan … Index Cond ((state,queue))`, tenant a post-Filter,
  `shared hit≈5591`). This is the gate-internal cost; the gate is off the request path
  (it runs inside `perform/1`) and already FAILS OPEN on the count, so O(queue-depth)
  here is acceptable. No new index is warranted for it (a count of N matching rows is
  inherently O(N) index entries; a `(tenant, queue, state)` index would lead with the
  high-cardinality tenant expression and fold the whole completed backlog under each
  tenant — strictly worse for the common case).

  **WORKER-scoped (`in_flight_ingestion_backlog/1` — US-36.3's SYNCHRONOUS request-path
  admission gate).** This one runs on `POST /knowledge/ingest[/batch]`, so its cost must
  be bounded by the CALLER's own backlog, not the fleet-wide `:ingestion` depth. It
  therefore filters `worker = 'Loopctl.Workers.ContentIngestionWorker' AND state IN ...
  AND args->>'tenant_id' = $1` — `worker` instead of `queue` (equivalent, since
  ContentIngestionWorker is the SOLE worker on the `:ingestion` queue). That predicate
  matches the partial COMPOSITE index `oban_jobs_ingestion_tenant_idx`
  (`((args->>'tenant_id'), inserted_at DESC, id DESC) WHERE worker = ContentIngestionWorker`,
  migration 20260713020000): the planner does a Bitmap/Index Scan with
  `Index Cond ((args->>'tenant_id') = $1)` — seeking straight to the caller's own
  ingestion rows and folding `state` as a cheap recheck. Cost is therefore O(the CALLER's
  own ingestion rows in the partial index — its recent history, since the index carries
  no `state` predicate but Oban prunes terminal `:ingestion` jobs after 7 days), NOT
  O(fleet-wide non-terminal on the `:ingestion` queue). A noisy tenant's flood inflates
  only its OWN scan. This is what makes AC-36.3.4's "cheap (single bounded count)" TRUE in cost, not
  merely in wall-clock: a noisy tenant's flood inflates only that tenant's own count, and
  the query no longer scans other tenants' rows — materially shrinking both the per-query
  cost AND the time it holds one of AdminRepo's 3 connections (the auth-hot-path pool), so
  the cross-tenant noisy-neighbor amplification of a fleet-wide scan is removed. Still
  HARD-BOUNDED by the 2 s statement_timeout and the gate still FAILS OPEN on
  raise/timeout (see `LoopctlWeb.KnowledgeIngestionController`), so the timeout is now
  only reachable at a per-tenant backlog far larger than the threshold the gate enforces.

  Each count runs under a per-query `SET LOCAL statement_timeout` (pgbouncer-safe — a
  startup `:parameters` timeout is rejected by Fly's pgbouncer with 08P01; see
  `Loopctl.HeavyRead`).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.ExitTag
  alias Loopctl.LocalGuc
  alias Loopctl.ObanConfig

  # `in_flight_ingestion_backlog/1` is the worker-scoped, index-backed backlog count
  # US-36.3's batch-ingest admission gate consults; declaring the behaviour makes
  # FairShare the default (production) implementation of that config-swappable DI seam.
  @behaviour Loopctl.Oban.BacklogCounterBehaviour

  # The four non-terminal Oban states — the GENERAL in-flight set (AC-36.2.1),
  # shared with US-36.3's batch-ingest backlog admission gate.
  @non_terminal_states ~w(available scheduled executing retryable)

  # The sole worker on the `:ingestion` queue. US-36.3's admission-gate count scopes
  # by this worker (not by queue) so the count rides the partial index
  # `oban_jobs_ingestion_tenant_idx` (WHERE worker = this) — see the moduledoc's
  # "Cost / index justification" (WORKER-scoped). Kept in sync with
  # `Loopctl.Workers.ContentIngestionWorker`'s `queue: :ingestion`.
  @ingestion_worker "Loopctl.Workers.ContentIngestionWorker"

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
  True when `tenant_id` is NOT among the lowest-`cap` holders of `queue`'s EXECUTING
  slots (AC-36.2.2) — i.e. `cap` or more of the tenant's OTHER executing jobs have a
  strictly lower `oban_jobs.id` than the running job (`job_id`). This RANK-based
  decision self-excludes the running job for free (`id < job_id`) AND breaks the
  co-fetch symmetry deterministically, so no set of co-fetched same-tenant jobs can
  ever all snooze together (see the moduledoc — "Rank-based decision").

  The CAP is read here, OUTSIDE the fail-open rescue below, so a malformed
  `OBAN_TENANT_FAIRSHARE_<QUEUE>` fails LOUD (crashes the job → visible) exactly like
  the snooze knobs, rather than being swallowed into a silent fail-open that disables
  fairness. Only the COUNT query FAILS OPEN (`false`) on error/timeout so the gate can
  never wedge a queue. `ObanConfig.fair_share_config/0` also validates every cap at
  BOOT, so at runtime this parse cannot fail anyway.
  """
  @spec over_fair_share?(binary(), atom(), pos_integer() | nil) :: boolean()
  def over_fair_share?(tenant_id, queue, job_id \\ nil)
      when is_binary(tenant_id) and is_atom(queue) do
    cap = ObanConfig.tenant_fair_share_cap(queue)
    over_cap?(tenant_id, queue, job_id, cap)
  end

  # The count-bearing half of the decision. FAILS OPEN (`false`) on any count
  # error/timeout — an unmeasurable count must NEVER block a job (SECURITY note: the
  # gate must not be able to wedge a queue). A malformed CAP is deliberately NOT caught
  # here (it is read in `over_fair_share?/3`, above this rescue) so it fails loud.
  defp over_cap?(tenant_id, queue, job_id, cap) do
    counter().lower_ranked_executing_count(tenant_id, queue, job_id) >= cap
  rescue
    e ->
      # The bounded CLASS, never `Exception.message/1`: a Postgrex/DBConnection message names
      # the backend host, database and role, and this line is reachable from any wedged-pool
      # moment on an ordinary job.
      fair_share_degraded(tenant_id, queue, ExitTag.tag(e))
  catch
    # #558: the rescue above covers only the RAISE shape, so this gate — which DOCUMENTS
    # failing open on any count error — failed CLOSED on the fault most likely to trigger it.
    # A DBConnection checkout against a wedged, saturated or unstarted pool EXITS, escaping
    # the rescue entirely, and the escape kills the Oban job rather than admitting it. The
    # gate exists so a counting problem never blocks work; on an exit it did the opposite.
    kind, reason when kind in [:exit, :throw] ->
      fair_share_degraded(tenant_id, queue, "#{kind}:#{ExitTag.tag(reason)}")
  end

  # One degrade path for both shapes, so the fail-open promise cannot drift between them.
  defp fair_share_degraded(tenant_id, queue, class) do
    Logger.warning("FairShare gate failed open on queue=#{queue} tenant=#{tenant_id} (#{class})")

    false
  end

  @doc """
  Broad in-flight count for `tenant_id` on `queue` across the four non-terminal
  states (`available`/`scheduled`/`executing`/`retryable`) — AC-36.2.1. QUEUE-scoped
  (the fair-share cost regime; see the moduledoc). US-36.3's admission gate uses the
  WORKER-scoped `in_flight_ingestion_backlog/1` instead.
  """
  @spec in_flight_count(binary(), atom() | binary()) :: non_neg_integer()
  def in_flight_count(tenant_id, queue) do
    count(tenant_id, {:queue, to_string(queue)}, @non_terminal_states, :all)
  end

  @doc """
  Broad in-flight `:ingestion` backlog for `tenant_id` across the four non-terminal
  states — the count US-36.3's SYNCHRONOUS batch-ingest admission gate consults (the
  429 backpressure check in `LoopctlWeb.KnowledgeIngestionController`).

  Scoped by `worker = ContentIngestionWorker` (the sole `:ingestion` worker) rather
  than by queue, so it rides the partial index `oban_jobs_ingestion_tenant_idx` and
  costs O(the caller's OWN ingestion backlog), not O(fleet-wide non-terminal on the
  `:ingestion` queue) — see the moduledoc's "Cost / index justification" (WORKER-scoped).
  This is the production implementation of `Loopctl.Oban.BacklogCounterBehaviour`.
  """
  @impl Loopctl.Oban.BacklogCounterBehaviour
  @spec in_flight_ingestion_backlog(binary()) :: non_neg_integer()
  def in_flight_ingestion_backlog(tenant_id) do
    count(tenant_id, {:worker, @ingestion_worker}, @non_terminal_states, :all)
  end

  @doc """
  Count of `tenant_id`'s currently-EXECUTING jobs on `queue` (AC-36.2.2) — the
  UNSCOPED slot-occupancy (counts every executing job, including any running caller).
  Used only by the fair-share gate's fallback (a `nil` `job_id`); the gate's normal
  decision path uses the self-excluding rank count instead (see `over_fair_share?/3`).
  Not currently reused outside this module (US-36.3 uses `in_flight_ingestion_backlog/1`).
  """
  @spec executing_count(binary(), atom() | binary()) :: non_neg_integer()
  def executing_count(tenant_id, queue) do
    count(tenant_id, {:queue, to_string(queue)}, ["executing"], :all)
  end

  # The gate's rank input: how many of the tenant's OTHER executing jobs on `queue`
  # have a strictly LOWER id than the running job (`job_id`). `< job_id` self-excludes
  # the running job for free and yields the deterministic co-fetch tie-break (see the
  # moduledoc). A `nil` job_id (bare `perform/1` struct in a test — off the real
  # dispatch path) has no rank, so we fall back to the plain unscoped executing count
  # (counts every executing job, including the caller).
  # Injected (`Loopctl.Oban.FairShareCounterBehaviour`) so the fail-open EXIT branch above is
  # reachable from a test; production resolves to this module.
  defp counter do
    Application.get_env(:loopctl, :fair_share_counter, __MODULE__)
  end

  @behaviour Loopctl.Oban.FairShareCounterBehaviour

  @impl Loopctl.Oban.FairShareCounterBehaviour
  def lower_ranked_executing_count(tenant_id, queue, job_id)

  def lower_ranked_executing_count(tenant_id, queue, job_id) when is_integer(job_id) do
    count(tenant_id, {:queue, to_string(queue)}, ["executing"], {:lower_than, job_id})
  end

  def lower_ranked_executing_count(tenant_id, queue, nil) do
    count(tenant_id, {:queue, to_string(queue)}, ["executing"], :all)
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
  # statement_timeout inside a transaction (pgbouncer-safe).
  #
  # `scope` selects which population the count leads on, and thus which index backs it
  # (see the moduledoc's "Cost / index justification"):
  #   * `{:queue, queue_str}`  — the fair-share regime; rides Oban's (state,queue) index.
  #   * `{:worker, worker_str}` — US-36.3's admission gate; rides the partial
  #     `oban_jobs_ingestion_tenant_idx` (WHERE worker = ContentIngestionWorker),
  #     bounding cost to the CALLER's own ingestion backlog.
  # Both `oban_jobs.queue` and `oban_jobs.worker` are text columns.
  #
  # `id_predicate` narrows the count: `:all` (public helpers — no id filter) or
  # `{:lower_than, job_id}` (the gate's rank input — only executing jobs with a
  # strictly lower id, which both self-excludes the caller and gives the deterministic
  # co-fetch tie-break; see the moduledoc).
  defp count(tenant_id, scope, states, id_predicate) do
    tenant_id_str = to_string(tenant_id)

    base =
      from(j in "oban_jobs",
        where:
          j.state in ^states and
            fragment("? ->> 'tenant_id' = ?", j.args, ^tenant_id_str),
        select: count(j.id)
      )

    query = base |> apply_scope(scope) |> apply_id_predicate(id_predicate)

    {:ok, result} =
      LocalGuc.timed_transaction(AdminRepo, @count_statement_timeout_ms, fn ->
        AdminRepo.one(query)
      end)

    result || 0
  end

  defp apply_scope(query, {:queue, queue_str}) do
    from(j in query, where: j.queue == ^queue_str)
  end

  defp apply_scope(query, {:worker, worker_str}) do
    from(j in query, where: j.worker == ^worker_str)
  end

  defp apply_id_predicate(query, :all), do: query

  defp apply_id_predicate(query, {:lower_than, job_id}) when is_integer(job_id) do
    from(j in query, where: j.id < ^job_id)
  end
end
