defmodule Loopctl.Telemetry.ScaleMetrics do
  @moduledoc """
  Scale-observability `Telemetry.Metrics` definitions (US-27.15, AC-27.15.1/.3).

  Turns the structured signals epic 27 already emits — `db_statement_timeout`
  (US-27.3), heavy-read latency (US-27.4), and recall under-fill (US-27.6b) — into
  aggregated metrics a reporter can scrape, so a degradation TREND is visible
  before it becomes an incident (instead of grepping 7-day logs after users hit it).

  These metrics are MERGED into `LoopctlWeb.Telemetry.metrics/0` and exposed to
  Fly's managed Prometheus by the reporter on the internal `:9568/metrics` port.
  `scale_metrics/0` has grown past its original US-27.15 scope as later stories
  added observability signals to the same list: #297 added the semantic-fallback
  counter and US-31.2 added the hybrid-provenance counter (both already present
  before this branch); US-33.1 adds TWO more, purely-additive metrics: per-pool
  connection-checkout `queue_time` distributions for `Loopctl.Repo` (the RLS pool,
  size 10) and `Loopctl.AdminRepo` (the BYPASSRLS pool, size 3). Ecto already emits
  `queue_time` (native time spent WAITING for a pooled connection) on every query
  telemetry event; before this branch only `heavy_read_repo.query.duration` was
  scraped, so there was no way to see where checkout contention lands between the
  two pools. See "Per-pool checkout queue_time (US-33.1)" below. US-34.1 adds TWO
  more, purely-additive: a per-(state, queue) `oban_jobs` depth gauge and an
  `:executing` orphan gauge — loopctl exported ZERO Oban metrics before this branch,
  so a stalled queue or a growing orphan pile-up (the motivating incident: a 17-day /
  110-orphan `:executing` stall went undetected for days) was invisible until users
  hit it. See "Oban observability (US-34.1)" below. `scale_metrics/0` now returns 9
  metrics total.

  ## The metrics (9 total)

    1. **Timeout / DB-error counter** — `loopctl.db.error.count`, keyed by
       `[:endpoint, :mapped_code]` (+ a cap-gated `:tenant_id`). `mapped_code`
       separates the `db_statement_timeout` (57014) counter the AC targets from the
       serialization / deadlock / catch-all classes. Sourced from
       `[:loopctl, :db, :error]` (emitted by `LoopctlWeb.DBErrorLogger`).
    2. **Heavy-read latency distribution** — `loopctl.heavy_read_repo.query.duration`,
       keyed by `[:endpoint]` ONLY (NO `:tenant_id` — endpoint × tenant × buckets is
       the multi-tenant cardinality bomb AC-27.15.3 forbids). Sourced from the Ecto
       query event `[:loopctl, :heavy_read_repo, :query]`, with `endpoint` read from
       `metadata.options[:endpoint]` (set by `Loopctl.HeavyRead.opts/1`).
    3. **Under-fill counter** — `loopctl.knowledge.vector_search.under_fill.count`,
       keyed by `[:endpoint]` (+ a cap-gated `:tenant_id`). Sourced from
       `[:loopctl, :knowledge, :vector_search, :under_fill]` (US-27.6b).
    4. **Semantic-fallback counter** (#297) — `loopctl.knowledge.semantic_fallback.count`,
       keyed by `[:reason]` ONLY (no `:tenant_id` — the reason set is fixed and
       small). Sourced from `[:loopctl, :knowledge, :semantic_fallback]`.
    5. **Hybrid-provenance counter** (US-31.2) — `loopctl.knowledge.hybrid_provenance.count`,
       keyed by `[:provenance, :hit]` (+ a cap-gated `:tenant_id`). Sourced from
       `[:loopctl, :knowledge, :hybrid_provenance]`.
    6. **RLS-pool checkout `queue_time` distribution** (US-33.1) —
       `loopctl.repo.checkout.queue_time`, with a static `[:repo]` tag (no cap gate
       needed). Sourced from the Ecto query event `[:loopctl, :repo, :query]`.
    7. **AdminRepo-pool checkout `queue_time` distribution** (US-33.1) —
       `loopctl.admin_repo.checkout.queue_time`, with a static `[:repo]` tag (no cap
       gate needed). Sourced from `[:loopctl, :admin_repo, :query]`.
    8. **Oban job-count gauge** (US-34.1, AC-34.1.1) — `loopctl.oban.jobs.count`, keyed
       by `[:state, :queue]` (BOTH fixed, small sets — no cap gate needed). Sourced
       from `[:loopctl, :oban, :jobs]`, emitted by `dispatch_oban_stats/0` polling
       `SELECT state, queue, count(*) FROM oban_jobs GROUP BY state, queue` and then
       ZERO-FILLING every `(state, queue)` combination in the known, bounded cartesian
       (7 Oban states × `Loopctl.ObanConfig.queues/0`) that the query did NOT return a
       row for — so a group that drains to zero (e.g. Lifeline rescues a backlog) emits
       an explicit `count: 0` instead of leaving the `last_value` gauge stuck at its
       last-seen non-zero value forever (a `last_value` store retains state per
       label-set with no TTL).
    9. **Oban `:executing` orphan gauge** (US-34.1, AC-34.1.2) —
       `loopctl.oban.executing_orphans.count`, untagged (a single scalar). Sourced
       from `[:loopctl, :oban, :orphans]`, emitted by the same `dispatch_oban_stats/0`
       poll — the count of `executing` jobs whose `attempted_at` is older than
       `:oban_metrics_orphan_threshold_minutes` (default 40 — deliberately ABOVE
       `Oban.Plugins.Lifeline`'s 30-minute `rescue_after`, so the gauge signals
       "Lifeline is falling behind / a job is wedged" rather than "a job is merely
       awaiting Lifeline's next normal sweep").

  ## Bounded cardinality (AC-27.15.3) — the no-leak contract

  Labels are SAFE DIMENSIONS only: `endpoint` (a matched controller.action / heavy-read
  endpoint atom — never a raw path with ids), `mapped_code` (a bounded DB-error class),
  and a cap-gated `tenant_id`. There is NO `:article_id` label, no raw vector / body /
  param ever reaches a tag — the upstream events carry id-only metadata.

  ### The tenant-label cap gate (no per-emit DB hit)

  `tenant_id` is a COUNTER label ONLY while the total tenant count is at or below
  `:metrics_tenant_label_cap` (default #{1000}); above the cap it is collapsed to the
  fixed sentinel `#{inspect(:_aggregated)}` so the label's cardinality is provably 1
  (per-tenant attribution then falls back to the 7-day logs, which still carry
  `tenant_id`). It is NEVER a label on the latency histogram (the buckets multiply).

  The gate is a boolean cached in `:persistent_term` under `#{inspect({__MODULE__, :tenant_label?})}`:

    * `tag_values` (`scale_tags/1`) reads it with `:persistent_term.get/2` — an O(1),
      lock-free read on the metric hot path, defaulting to `false` (drop/aggregate the
      label) if unseeded, so an un-warmed boot can NEVER emit an unbounded label.
    * `refresh_tenant_label_gate/0` recomputes `Tenants.count() <= cap` and writes the
      boolean. It is wired into `LoopctlWeb.Telemetry`'s `telemetry_poller` periodic
      measurements (every 10s) and is the ONLY place that touches the DB — so the
      cardinality decision costs one cheap `COUNT(*)` per poll interval, not one per
      metric emission.

  ### Why a SENTINEL, not an omitted tag

  A Prometheus metric series must carry a CONSISTENT label set across every emission;
  a `tag_values` map that sometimes includes `:tenant_id` and sometimes omits it would
  make the same metric flap between two label shapes (the core reporter would treat
  them as distinct series and can error on the inconsistency). Holding the tag list
  FIXED in the metric definition and collapsing the VALUE to a single sentinel when
  gated keeps the series shape stable AND pins the tenant dimension's cardinality to
  exactly 1 when over the cap. Below the cap the cardinality is bounded by the cap
  itself (≤ #{1000} by default).

  ## Oban observability (US-34.1)

  `dispatch_oban_stats/0` is the periodic-measurement counterpart to
  `refresh_tenant_label_gate/0`, but wired into its OWN, independently-configurable
  `telemetry_poller` instance in `LoopctlWeb.Telemetry` (`:oban_metrics_poll_interval_ms`,
  default 10s) rather than the shared tenant-label-gate poller — the heavier,
  unindexed `oban_jobs` GROUP BY aggregate this triggers warrants its own tunable
  cadence, and decoupling the pollers also means a raise here can never crash the
  tenant-label gate's refresh (see below). It polls `oban_jobs` (via the
  `Loopctl.Telemetry.ObanStatsBehaviour` DI seam, defaulting to the real
  `Loopctl.Telemetry.ObanStats`) for:

    * per-`(state, queue)` row counts (AC-34.1.1), ZERO-FILLED across the full known
      cartesian and each combination emitted as its own `[:loopctl, :oban, :jobs]`
      measurement — `state` is Oban's fixed 7-value enum (`available`/`scheduled`/
      `executing`/`retryable`/`completed`/`discarded`/`cancelled`) and `queue` is the
      fixed 9-queue set (`Loopctl.ObanConfig`), so BOTH tags are bounded WITHOUT a cap
      gate — unlike `tenant_id` above, there is no unbounded dimension here to guard
      against (AC-34.1.5). The GROUP BY query only returns rows for NON-EMPTY groups,
      so `emit_oban_job_state_counts/0` fills in an explicit `count: 0` for every
      `(state, queue)` pair the query didn't return — otherwise a group that drains to
      zero (e.g. a backlog Lifeline just rescued) would leave the `last_value` gauge
      permanently stuck at its last-seen non-zero value (the reporter's `LastValue`
      store has no TTL/expiry), defeating the whole point of watching a queue clear.
    * the `:executing` orphan count (AC-34.1.2) — jobs stuck `executing` longer than
      `:oban_metrics_orphan_threshold_minutes` (default 40 — deliberately ABOVE
      `Oban.Plugins.Lifeline`'s 30-minute `rescue_after` in `config/config.exs`, so a
      job merely awaiting Lifeline's next normal sweep is never mistaken for "Lifeline
      is falling behind / a job is wedged") — as a single untagged
      `[:loopctl, :oban, :orphans]` measurement (unaffected by zero-fill: it is a
      scalar that always emits, including 0).

  `telemetry_poller` does NOT crash its poller GenServer on a raising measurement —
  `make_measurement/1` catches `Class:Reason`, logs one error, and the poller
  process survives. But surviving is not enough: `handle_info(:collect, ...)` then
  drops the raising measurement from poller state and never retries it, so an
  UNCAUGHT raise here would PERMANENTLY disable this gauge for the life of the
  BEAM (worse than a crash, which `:one_for_one` would restart) — silently, after
  one log line. So `dispatch_oban_stats/0` rescues `ANY` exception itself
  (AC-34.1.3): a fault during either query is caught, logged at `:warning`, and the
  poll is skipped for that interval — the Prometheus gauges simply hold their
  last-scraped value (no metric corruption) and the NEXT interval's poll still
  runs.
  """

  import Telemetry.Metrics

  require Logger

  alias Loopctl.Tenants

  @persistent_term_key {__MODULE__, :tenant_label?}

  # The fixed sentinel a `tenant_id` label collapses to when the gate is OFF (over the
  # tenant-count cap, or the gate is unseeded). Keeps the tenant label's cardinality at
  # exactly 1 while preserving a consistent Prometheus series shape.
  @aggregated_sentinel :_aggregated

  @default_tenant_label_cap 1_000

  @doc """
  All 9 scale metrics: the original US-27.15 trio, #297's semantic-fallback
  counter, US-31.2's hybrid-provenance counter, US-33.1's two per-pool checkout
  `queue_time` distributions, and US-34.1's two Oban `oban_jobs` gauges. Appended to
  `LoopctlWeb.Telemetry.metrics/0`.
  """
  @spec scale_metrics() :: [Telemetry.Metrics.t()]
  def scale_metrics do
    [
      # 1. DB-error counter (the 57014 `db_statement_timeout` source). `mapped_code`
      #    separates the timeout class from serialization/deadlock/catch-all. The
      #    counter MAY carry a cap-gated `tenant_id` (sentinel when over cap).
      counter("loopctl.db.error.count",
        event_name: [:loopctl, :db, :error],
        measurement: :count,
        description: "Mapped DB errors surfaced to clients, by endpoint and mapped_code.",
        tags: [:endpoint, :mapped_code, :tenant_id],
        tag_values: &scale_tags/1
      ),

      # 2. Heavy-read latency distribution, by endpoint. NO tenant tag (AC-27.15.3 —
      #    endpoint × tenant × buckets blows up in a multi-tenant SaaS).
      distribution("loopctl.heavy_read_repo.query.duration",
        event_name: [:loopctl, :heavy_read_repo, :query],
        measurement: :total_time,
        unit: {:native, :millisecond},
        description: "Heavy-read (vector / enumeration) query latency, by endpoint.",
        tags: [:endpoint],
        tag_values: &latency_tags/1,
        reporter_options: [
          buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
        ]
      ),

      # 3. Recall under-fill counter (US-27.6b), by endpoint. MAY carry a cap-gated
      #    `tenant_id` (sentinel when over cap).
      counter("loopctl.knowledge.vector_search.under_fill.count",
        event_name: [:loopctl, :knowledge, :vector_search, :under_fill],
        measurement: :requested,
        description: "Vector-search recall under-fill events, by endpoint.",
        tags: [:endpoint, :tenant_id],
        tag_values: &scale_tags/1
      ),

      # 4. Semantic-fallback counter (#297), by REASON only. Turns the silent
      #    semantic→keyword degradation into an alertable trend. `reason` is a
      #    BOUNDED, sanitized tag set (no api key / provider body / raw query ever
      #    reaches it), so this needs NO tenant_id label — the reason dimension is
      #    fixed and small, and per-tenant attribution stays in the 7-day logs
      #    (which carry tenant_id). NO tenant label = no multi-tenant cardinality
      #    bomb (AC-27.15.3).
      counter("loopctl.knowledge.semantic_fallback.count",
        event_name: [:loopctl, :knowledge, :semantic_fallback],
        measurement: :count,
        description: "Semantic search degraded to keyword-only / contributed nothing, by reason.",
        tags: [:reason],
        tag_values: &semantic_fallback_tags/1
      ),

      # 5. Hybrid-resolver provenance counter (US-31.2, finding 6): every
      #    `hybrid_search/3` decision, by `provenance` (curated/retrieved) and `hit`
      #    (non-empty/empty page). Fires unconditionally (unlike the
      #    `article_access_events` recording, which cannot represent a MISS or a
      #    keyless call), so the hit/miss + keyless dimension stays observable. MAY
      #    carry a cap-gated `tenant_id` (sentinel when over cap).
      counter("loopctl.knowledge.hybrid_provenance.count",
        event_name: [:loopctl, :knowledge, :hybrid_provenance],
        measurement: :count,
        description:
          "Hybrid resolver (US-31.2) provenance decisions, by provenance, hit/miss, and tenant.",
        tags: [:provenance, :hit, :tenant_id],
        tag_values: &hybrid_provenance_tags/1
      ),

      # 6. Per-pool checkout queue_time (US-33.1): the RLS `Loopctl.Repo` pool (size
      #    10). Sourced from Ecto's default query event for that repo module
      #    (`[:loopctl, :repo, :query]`). `repo` is a STATIC single-value tag (not
      #    read from metadata) — the repo identity is encoded in the event name
      #    itself, so `tag_values` can never raise and needs no cap gate (AC-33.1.2).
      #    Distinct name from the existing `loopctl.repo.query.queue_time` SUMMARY in
      #    `LoopctlWeb.Telemetry.base_metrics/0` — same name + different metric type
      #    would conflict in the Prometheus reporter.
      distribution("loopctl.repo.checkout.queue_time",
        event_name: [:loopctl, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :millisecond},
        description: "Connection-checkout wait for the RLS Repo pool, by repo.",
        tags: [:repo],
        tag_values: &queue_time_tags_repo/1,
        reporter_options: [
          buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000]
        ]
      ),

      # 7. Per-pool checkout queue_time (US-33.1): the BYPASSRLS `Loopctl.AdminRepo`
      #    pool (size 3). Sourced from Ecto's default query event for that repo
      #    module (`[:loopctl, :admin_repo, :query]`). There was previously NO
      #    queue_time metric at all for this pool.
      distribution("loopctl.admin_repo.checkout.queue_time",
        event_name: [:loopctl, :admin_repo, :query],
        measurement: :queue_time,
        unit: {:native, :millisecond},
        description: "Connection-checkout wait for the AdminRepo pool, by repo.",
        tags: [:repo],
        tag_values: &queue_time_tags_admin_repo/1,
        reporter_options: [
          buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000]
        ]
      ),

      # 8. Oban per-(state, queue) job-count gauge (US-34.1, AC-34.1.1). `last_value`
      #    (Telemetry.Metrics' gauge type) so the reporter always reflects the MOST
      #    RECENT poll, not a running sum. `state` (Oban's fixed 7-value enum) and
      #    `queue` (the fixed 9-queue set, `Loopctl.ObanConfig`) are BOTH bounded — no
      #    tenant/args-derived tag, no cap gate needed (AC-34.1.5).
      last_value("loopctl.oban.jobs.count",
        event_name: [:loopctl, :oban, :jobs],
        measurement: :count,
        description: "Oban oban_jobs row count, by state and queue (polled every 10s).",
        tags: [:state, :queue],
        tag_values: &oban_job_tags/1
      ),

      # 9. Oban `:executing` orphan gauge (US-34.1, AC-34.1.2): jobs stuck `executing`
      #    past the configured threshold (default 40 min, deliberately above
      #    Oban.Plugins.Lifeline's 30-minute rescue_after) — the signal that Lifeline is
      #    falling behind or a job is genuinely wedged. Untagged — a single scalar value,
      #    so there is no cardinality question at all.
      last_value("loopctl.oban.executing_orphans.count",
        event_name: [:loopctl, :oban, :orphans],
        measurement: :count,
        description:
          "Oban jobs stuck in :executing past the orphan threshold (polled every 10s).",
        tags: []
      )
    ]
  end

  @doc """
  `tag_values` for the semantic-fallback counter (#297). Emits ONLY the bounded
  `reason` label (never `tenant_id` — the reason set is fixed and small, so no cap
  gate is needed). Defaults a missing reason to `"unknown"` so the label is never
  blank.
  """
  @spec semantic_fallback_tags(map()) :: map()
  def semantic_fallback_tags(metadata) do
    %{reason: Map.get(metadata, :reason, "unknown")}
  end

  @doc """
  `tag_values` for the hybrid-provenance counter (US-31.2). `provenance` and `hit` are
  small, fixed-cardinality dimensions (2 values each) so they need no cap gate;
  `tenant_id` reuses the SAME cap-gated sentinel collapse as the other two counters
  (`gated_tenant_id/1`) to keep its cardinality bounded identically.
  """
  @spec hybrid_provenance_tags(map()) :: map()
  def hybrid_provenance_tags(metadata) do
    %{
      provenance: Map.get(metadata, :provenance, "unknown"),
      hit: Map.get(metadata, :hit, false),
      tenant_id: gated_tenant_id(metadata)
    }
  end

  @doc """
  `tag_values` for the Oban per-(state, queue) gauge (US-34.1). Both dimensions are
  bounded, fixed-cardinality sets (7 states, 9 queues — see `Loopctl.ObanConfig`), so
  — unlike the tenant-label-gated counters above — this needs NO cap gate. Defaults a
  missing/nil state or queue to `"unknown"` so the label is never blank (mirrors
  `scale_tags/1`).
  """
  @spec oban_job_tags(map()) :: map()
  def oban_job_tags(metadata) do
    %{
      state: Map.get(metadata, :state) || "unknown",
      queue: Map.get(metadata, :queue) || "unknown"
    }
  end

  @doc """
  `tag_values` for the two COUNTERS.

  Always returns the full fixed label set so the Prometheus series shape is stable:

    * `:endpoint` — `metadata.endpoint` (a bounded controller.action / endpoint atom),
      defaulting to `:unknown`.
    * `:mapped_code` — `metadata.mapped_code` for the DB-error counter (defaulting to
      `"unknown"`); the under-fill event has none, so this key is simply absent from
      that counter's `:tags` and ignored.
    * `:tenant_id` — `metadata.tenant_id` ONLY when the cap gate is ON; otherwise the
      `#{inspect(@aggregated_sentinel)}` sentinel (cardinality 1). A missing/`nil`
      tenant_id also collapses to the sentinel so the label is never blank.
  """
  @spec scale_tags(map()) :: map()
  def scale_tags(metadata) do
    %{
      endpoint: Map.get(metadata, :endpoint, :unknown),
      mapped_code: Map.get(metadata, :mapped_code, "unknown"),
      tenant_id: gated_tenant_id(metadata)
    }
  end

  @doc """
  `tag_values` for the latency DISTRIBUTION. Endpoint ONLY — NEVER tenant_id
  (AC-27.15.3: tenant on a histogram multiplies by every bucket). `endpoint` comes
  from `metadata.options[:endpoint]` (set by `Loopctl.HeavyRead.opts/1`), defaulting
  to `:unknown` for any heavy-pool query issued without an endpoint tag.
  """
  @spec latency_tags(map()) :: map()
  def latency_tags(metadata) do
    options = Map.get(metadata, :options) || []
    %{endpoint: Keyword.get(options, :endpoint, :unknown)}
  end

  @doc """
  `tag_values` for the RLS `Loopctl.Repo` checkout `queue_time` distribution
  (US-33.1). Returns a FIXED, static `%{repo: "repo"}` map — the repo identity is
  already encoded in the event name (`[:loopctl, :repo, :query]`), so this ignores
  `metadata` entirely and cannot raise regardless of what Ecto passes (AC-33.1.4).
  """
  @spec queue_time_tags_repo(map()) :: map()
  def queue_time_tags_repo(_metadata), do: %{repo: "repo"}

  @doc """
  `tag_values` for the `Loopctl.AdminRepo` checkout `queue_time` distribution
  (US-33.1). Returns a FIXED, static `%{repo: "admin_repo"}` map for the same
  reason as `queue_time_tags_repo/1` — the event name already identifies the pool.
  """
  @spec queue_time_tags_admin_repo(map()) :: map()
  def queue_time_tags_admin_repo(_metadata), do: %{repo: "admin_repo"}

  # The cap gate read on the hot path: a lock-free O(1) persistent_term lookup,
  # defaulting to `false` (aggregate) if unseeded — an un-warmed boot can never emit
  # an unbounded tenant label.
  defp gated_tenant_id(metadata) do
    if tenant_label?() do
      case Map.get(metadata, :tenant_id) do
        nil -> @aggregated_sentinel
        tenant_id -> tenant_id
      end
    else
      @aggregated_sentinel
    end
  end

  @doc """
  Whether the `tenant_id` counter label is currently allowed (tenant count ≤ cap).

  Reads the boolean from `:persistent_term`, defaulting to `false` (drop/aggregate)
  when unseeded — so the safe, bounded behavior holds before the first poll.
  """
  @spec tenant_label?() :: boolean()
  def tenant_label? do
    :persistent_term.get(@persistent_term_key, false)
  end

  @doc """
  Recomputes the tenant-label cap gate and caches it in `:persistent_term`.

  This is the `telemetry_poller` periodic measurement (wired in
  `LoopctlWeb.Telemetry`). It performs the ONLY DB read in the gating mechanism — one
  cheap `Tenants.count()` per poll interval — so the per-emit `tag_values` path never
  touches the DB. A DB fault during the count is fail-soft: the gate is forced OFF
  (aggregate to the sentinel) rather than crashing the poller, keeping cardinality
  bounded. Returns the boolean it stored.

  Note: this returns the gate boolean rather than calling `:telemetry.execute/3`
  itself — the poller only needs the side effect of refreshing the cached gate, and
  no metric is derived from a `[:loopctl, :telemetry, :tenant_label_gate]` event.
  """
  @spec refresh_tenant_label_gate() :: boolean()
  def refresh_tenant_label_gate do
    allowed? =
      try do
        Tenants.count() <= tenant_label_cap()
      rescue
        # Fail-soft to a BOUNDED gate (force OFF → aggregate to the sentinel) ONLY for DB
        # faults — a transient connection / ownership / Postgres error must not crash the
        # shared poller. But the rescue is NARROW (security AREA-6): a persistently-failing
        # gate (schema drift / misconfig that always raises) would otherwise stay silently
        # stuck OFF, so we LOG it at :warning to make it visible. A genuine programmer
        # error (anything outside the DB-exception set) is re-raised so it still surfaces
        # rather than being masked as "gate off".
        e in [Postgrex.Error, DBConnection.ConnectionError, DBConnection.OwnershipError] ->
          Logger.warning(
            "tenant-label gate refresh failed (#{inspect(e.__struct__)}); forcing gate OFF " <>
              "(tenant_id label aggregates to the sentinel until the count succeeds)"
          )

          false
      end

    # Put ONLY on an actual transition (team review F3). `:persistent_term.put/2` triggers
    # a global term-table scan, so writing the unchanged steady-state value every 10s is
    # wasteful; the gate is stable once a fleet settles above/below the cap, so this makes
    # the steady-state cost zero puts and writes only on a real gate flip.
    if :persistent_term.get(@persistent_term_key, :unset) != allowed? do
      :persistent_term.put(@persistent_term_key, allowed?)
    end

    allowed?
  end

  @doc """
  The documented tenant-count cap (`:metrics_tenant_label_cap`, default
  #{@default_tenant_label_cap}). At or below it, the `tenant_id` counter label is
  allowed; above it, the label collapses to the aggregated sentinel.
  """
  @spec tenant_label_cap() :: non_neg_integer()
  def tenant_label_cap do
    Application.get_env(:loopctl, :metrics_tenant_label_cap, @default_tenant_label_cap)
  end

  @doc "The sentinel value a gated-off `tenant_id` label collapses to."
  @spec aggregated_sentinel() :: atom()
  def aggregated_sentinel, do: @aggregated_sentinel

  @default_oban_orphan_threshold_minutes 40

  # Oban's fixed, bounded state enum (7 values) — used to zero-fill the
  # per-(state, queue) gauge's known cartesian (see `emit_oban_job_state_counts/0`).
  @oban_states ~w(available scheduled executing retryable completed discarded cancelled)

  @doc """
  Polls `oban_jobs` for per-`(state, queue)` counts (AC-34.1.1) and the `:executing`
  orphan count (AC-34.1.2), emitting the `[:loopctl, :oban, :jobs]` /
  `[:loopctl, :oban, :orphans]` telemetry events the two `last_value` gauges above
  consume. This is the `telemetry_poller` periodic measurement wired into its OWN
  poller instance in `LoopctlWeb.Telemetry` (`:oban_metrics_poll_interval_ms`,
  default 10s — independently configurable from the tenant-label-gate poller).

  Self-rescuing (AC-34.1.3 / TC-34.1.3), and DELIBERATELY WIDE: `telemetry_poller`
  catches any raise from a periodic measurement itself, but its recovery is to log
  once and drop that measurement from poller state FOREVER — it does not retry, and
  the poller process never crashes, so `:one_for_one` never gets a chance to
  restart it either. An uncaught raise here would therefore permanently freeze both
  gauges at their last-scraped value for the rest of the BEAM's lifetime, which is
  worse than a crash. So this rescues ANY exception (not just the DB-connection
  classes) — logs at `:warning` and returns `:ok` WITHOUT emitting, leaving the
  Prometheus gauges holding their last-scraped value until the next poll interval,
  which still runs.
  """
  @spec dispatch_oban_stats() :: :ok
  def dispatch_oban_stats do
    emit_oban_job_state_counts()
    emit_oban_executing_orphans()
    :ok
  rescue
    e ->
      Logger.warning(
        "oban_jobs metrics poll failed (#{inspect(e.__struct__)}); skipping this interval"
      )

      :ok
  end

  # Zero-fills the bounded (state, queue) cartesian (AC-34.1.1, finding: last_value
  # gauge going permanently stale on drain-to-zero). `job_state_counts/0`'s
  # `GROUP BY state, queue` returns NO row for an empty group, so relying on it alone
  # would mean a group that drains to zero (e.g. Lifeline just rescued a backlog)
  # never emits again — the `last_value` gauge would hold its last-seen non-zero
  # value FOREVER (the reporter's LastValue store has no TTL/expiry). Instead this
  # emits one measurement per pair in `@oban_states × Loopctl.ObanConfig.queues/0`
  # (both fixed, bounded sets — AC-34.1.5), defaulting to `count: 0` for any pair the
  # query didn't return a row for. Any group the query DID return that falls OUTSIDE
  # the known cartesian (e.g. a job queued under a name not in `ObanConfig` — a real
  # misconfiguration, not expected in practice) is still emitted rather than silently
  # dropped, so a genuine anomaly stays observable instead of being hidden by the
  # zero-fill.
  defp emit_oban_job_state_counts do
    observed = oban_stats_impl().job_state_counts()
    counts_by_group = Map.new(observed, fn {state, queue, count} -> {{state, queue}, count} end)

    known_groups = for state <- @oban_states, queue <- oban_queue_names(), do: {state, queue}
    observed_groups = Enum.map(observed, fn {state, queue, _count} -> {state, queue} end)

    for {state, queue} <- Enum.uniq(known_groups ++ observed_groups) do
      count = Map.get(counts_by_group, {state, queue}, 0)

      :telemetry.execute(
        [:loopctl, :oban, :jobs],
        %{count: count},
        %{state: state, queue: queue}
      )
    end
  end

  defp oban_queue_names do
    Enum.map(Loopctl.ObanConfig.queues(), fn {queue, _size} -> Atom.to_string(queue) end)
  end

  defp emit_oban_executing_orphans do
    count = oban_stats_impl().executing_orphan_count(oban_orphan_threshold_minutes())
    :telemetry.execute([:loopctl, :oban, :orphans], %{count: count}, %{})
  end

  defp oban_stats_impl do
    Application.get_env(:loopctl, :oban_stats_query, Loopctl.Telemetry.ObanStats)
  end

  @doc """
  The `:executing` orphan threshold, in minutes (AC-34.1.2). Jobs stuck `executing`
  longer than this are counted as orphans. Defaults to
  #{@default_oban_orphan_threshold_minutes} minutes — deliberately ABOVE
  `Oban.Plugins.Lifeline`'s 30-minute `rescue_after` window in `config/config.exs`,
  so the gauge signals the case Lifeline should already have rescued but hasn't
  (falling behind, or the job is genuinely wedged) rather than a job that has simply
  crossed 30 minutes and is still awaiting Lifeline's next normal periodic sweep.
  """
  @spec oban_orphan_threshold_minutes() :: pos_integer()
  def oban_orphan_threshold_minutes do
    case Application.get_env(
           :loopctl,
           :oban_metrics_orphan_threshold_minutes,
           @default_oban_orphan_threshold_minutes
         ) do
      minutes when is_integer(minutes) and minutes > 0 -> minutes
      _ -> @default_oban_orphan_threshold_minutes
    end
  end
end
