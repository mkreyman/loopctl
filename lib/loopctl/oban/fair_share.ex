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

  The public `executing_count/2` / `in_flight_count/2` helpers (`in_flight_count/2`
  is reused by US-36.3's batch-ingest backlog admission gate — see below) are
  UNSCOPED counts — they intentionally do NOT apply the
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
      (`available`/`scheduled`/`executing`/`retryable`), the GENERAL helper reused by
      US-36.3's batch-ingest backlog admission gate (the 429 backpressure check in
      `LoopctlWeb.KnowledgeIngestionController.create_batch/2`).
    * `executing_count/2` — only `executing`, the slot-occupancy the fair-share gate
      decides on (AC-36.2.2).

  ### Cost / index justification

  The query filters `queue = $1 AND state (= or IN) ... AND args->>'tenant_id' = $2`.
  Oban's own default index `oban_jobs_state_queue_priority_scheduled_at_id_index`
  leads with `(state, queue)`, so the planner Index-Scans exactly the NON-TERMINAL
  population for that `(state, queue)` and applies `args->>'tenant_id'` as a filter
  over it — the enormous `completed`/`discarded` backlog (pruned after 7 days, but
  still the bulk of the table) is never touched because `state` is the leading column.

  The cost is therefore O(non-terminal rows on that `(state, queue)`), NOT sub-ms
  unconditionally. Two regimes, both measured on the dev DB:

    * BENIGN (~18k jobs, all terminal/pruned): the `executing` count is
      `Index Scan … Index Cond ((state,queue)) … shared hit≈3`, ~0.05 ms; the 4-state
      count `shared hit≈12`, ~0.05 ms.
    * ONE-TENANT FLOOD (the scenario this story targets — a 50-item ingest fanning
      out thousands of contiguous `available` rows): synthesised 5k `available`
      `:embeddings` rows for one tenant (10k non-terminal on the queue in total) and
      EXPLAIN-ANALYZEd the 4-state `in_flight_count`. Result: still an
      `Index Scan using …_state_queue_… (Index Cond ((state,queue)))` with the tenant
      as a post-Filter — `shared hit≈5591`, **~3.5 ms** at 10k scanned rows. It scans
      every non-terminal row on the queue (the tenant filter does NOT reduce a
      single-tenant flood), so the count grows LINEARLY with the queue's non-terminal
      depth, but stays low-single-digit-ms at the flood sizes this feature contends
      with and is HARD-BOUNDED by the 2 s `SET LOCAL statement_timeout` below — it can
      never pin a connection. This bound makes it safe for US-36.3's synchronous
      per-request admission-gate use; that gate additionally FAILS OPEN if this count
      raises/times out (an unmeasurable backlog admits the batch, never 500 — see
      `LoopctlWeb.KnowledgeIngestionController`), and if it ever needs a flood-
      independent cost it should cap the count (e.g. `LIMIT`-bounded existence probe),
      not add an index (see next).

  NO new index is warranted. A count of N matching rows is inherently O(N) index
  entries even with a perfect covering index, so no index makes a single-tenant flood
  count sub-linear; and a `(args->>'tenant_id', queue, state)` index would be strictly
  WORSE for the common case, leading with the high-cardinality tenant expression and
  folding the whole completed backlog under each tenant. Each count runs under a
  per-query `SET LOCAL statement_timeout` (pgbouncer-safe — a startup `:parameters`
  timeout is rejected by Fly's pgbouncer with 08P01; see `Loopctl.HeavyRead`).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.ObanConfig

  # `in_flight_count/2` is the broad non-terminal count US-36.3's batch-ingest
  # admission gate consults; declaring the behaviour makes FairShare the default
  # (production) implementation of that config-swappable DI seam.
  @behaviour Loopctl.Oban.BacklogCounterBehaviour

  # The four non-terminal Oban states — the GENERAL in-flight set (AC-36.2.1),
  # shared with US-36.3's batch-ingest backlog admission gate.
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
    lower_ranked_executing_count(tenant_id, queue, job_id) >= cap
  rescue
    e ->
      Logger.warning(
        "FairShare gate failed open on queue=#{queue} tenant=#{tenant_id}: " <>
          Exception.message(e)
      )

      false
  end

  @doc """
  Broad in-flight count for `tenant_id` on `queue` across the four non-terminal
  states (`available`/`scheduled`/`executing`/`retryable`) — AC-36.2.1. This is the
  GENERAL helper US-36.3's batch-ingest backlog admission gate reuses (the 429
  backpressure check in `LoopctlWeb.KnowledgeIngestionController.create_batch/2`).
  """
  @spec in_flight_count(binary(), atom() | binary()) :: non_neg_integer()
  def in_flight_count(tenant_id, queue) do
    count(tenant_id, queue, @non_terminal_states, :all)
  end

  @doc """
  Count of `tenant_id`'s currently-EXECUTING jobs on `queue` (AC-36.2.2) — the
  UNSCOPED slot-occupancy (counts every executing job, including any running caller).
  Used only by the fair-share gate's fallback (a `nil` `job_id`); the gate's normal
  decision path uses the self-excluding rank count instead (see `over_fair_share?/3`).
  Not currently reused outside this module (US-36.3 reuses `in_flight_count/2` only).
  """
  @spec executing_count(binary(), atom() | binary()) :: non_neg_integer()
  def executing_count(tenant_id, queue) do
    count(tenant_id, queue, ["executing"], :all)
  end

  # The gate's rank input: how many of the tenant's OTHER executing jobs on `queue`
  # have a strictly LOWER id than the running job (`job_id`). `< job_id` self-excludes
  # the running job for free and yields the deterministic co-fetch tie-break (see the
  # moduledoc). A `nil` job_id (bare `perform/1` struct in a test — off the real
  # dispatch path) has no rank, so we fall back to the plain unscoped executing count
  # (counts every executing job, including the caller).
  defp lower_ranked_executing_count(tenant_id, queue, job_id) when is_integer(job_id) do
    count(tenant_id, queue, ["executing"], {:lower_than, job_id})
  end

  defp lower_ranked_executing_count(tenant_id, queue, nil) do
    count(tenant_id, queue, ["executing"], :all)
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
  #
  # `id_predicate` narrows the count: `:all` (public helpers — no id filter) or
  # `{:lower_than, job_id}` (the gate's rank input — only executing jobs with a
  # strictly lower id, which both self-excludes the caller and gives the deterministic
  # co-fetch tie-break; see the moduledoc).
  defp count(tenant_id, queue, states, id_predicate) do
    queue_str = to_string(queue)
    tenant_id_str = to_string(tenant_id)

    base =
      from(j in "oban_jobs",
        where:
          j.queue == ^queue_str and j.state in ^states and
            fragment("? ->> 'tenant_id' = ?", j.args, ^tenant_id_str),
        select: count(j.id)
      )

    query = apply_id_predicate(base, id_predicate)

    {:ok, result} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!("SET LOCAL statement_timeout = #{@count_statement_timeout_ms}")
        AdminRepo.one(query)
      end)

    result || 0
  end

  defp apply_id_predicate(query, :all), do: query

  defp apply_id_predicate(query, {:lower_than, job_id}) when is_integer(job_id) do
    from(j in query, where: j.id < ^job_id)
  end
end
