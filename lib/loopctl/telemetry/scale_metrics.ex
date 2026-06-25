defmodule Loopctl.Telemetry.ScaleMetrics do
  @moduledoc """
  Scale-observability `Telemetry.Metrics` definitions (US-27.15, AC-27.15.1/.3).

  Turns the structured signals epic 27 already emits — `db_statement_timeout`
  (US-27.3), heavy-read latency (US-27.4), and recall under-fill (US-27.6b) — into
  three aggregated metrics a reporter can scrape, so a degradation TREND is visible
  before it becomes an incident (instead of grepping 7-day logs after users hit it).

  The three metrics are MERGED into `LoopctlWeb.Telemetry.metrics/0` and exposed to
  Fly's managed Prometheus by the reporter on the internal `:9568/metrics` port.

  ## The three metrics

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
  """

  import Telemetry.Metrics

  alias Loopctl.Tenants

  @persistent_term_key {__MODULE__, :tenant_label?}

  # The fixed sentinel a `tenant_id` label collapses to when the gate is OFF (over the
  # tenant-count cap, or the gate is unseeded). Keeps the tenant label's cardinality at
  # exactly 1 while preserving a consistent Prometheus series shape.
  @aggregated_sentinel :_aggregated

  @default_tenant_label_cap 1_000

  @doc """
  The three scale metrics (US-27.15). Appended to `LoopctlWeb.Telemetry.metrics/0`.
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
      )
    ]
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
        _ -> false
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
end
