# Runbook: Knowledge Scale Metrics Grafana dashboard (US-27.15 / #196)

> **What this is.** A ready-to-import Grafana dashboard
> ([`scale-metrics-dashboard.json`](scale-metrics-dashboard.json)) that **visualizes**
> the three scale-observability metrics US-27.15 already ships. It is the tracked
> follow-up recorded as **GitHub #196** in the
> [`knowledge-scale.md`](../runbooks/knowledge-scale.md#metrics--alerting-us-2715)
> runbook ("Bespoke Grafana dashboard JSON ... a recorded backlog follow-up").
>
> **What this is NOT.** It is **not** an alerting mechanism. `fly-metrics.net`'s managed
> Grafana has **alerting DISABLED** — PromQL here only draws trends. The signal that
> actually **fires** on a breach is the in-app **`Loopctl.Telemetry.ScaleAlerts`**
> webhook (see [Alerting](#alerting-is-not-in-this-dashboard) below).

---

## Where the data comes from

The three metrics are `Telemetry.Metrics` defined in
[`lib/loopctl/telemetry/scale_metrics.ex`](../../lib/loopctl/telemetry/scale_metrics.ex),
merged into `LoopctlWeb.Telemetry.metrics/0`, and exported by the
`telemetry_metrics_prometheus` reporter on the **internal `:9568/metrics`** port (started
through the fault-isolating `Loopctl.Telemetry.MetricsReporter` wrapper). Fly's **managed
Prometheus** scrapes `:9568` over the private 6PN network (`fly.toml [metrics]`), and the
series land in **`fly-metrics.net` Grafana**. That is the datasource this dashboard reads.

`:9568` is internal-only (not in `fly.toml`'s public `http_service`); the reporter is off
in `:test` and off by default in dev — set `config :loopctl, :metrics_reporter_enabled,
true` in `config/dev.exs` to read `localhost:9568/metrics` locally.

## How to import

1. Open **`fly-metrics.net`** (Fly's managed Grafana for your org) and sign in.
2. **Dashboards → New → Import**.
3. Upload `docs/observability/scale-metrics-dashboard.json` (or paste its contents).
4. When prompted, pick your **Prometheus** datasource for the dashboard's `datasource`
   variable. The dashboard uses a datasource **template variable** (not a hard-coded uid),
   so it is portable across orgs / any Prometheus that scrapes the same `/metrics`.
5. Save. Default range is `now-6h`, auto-refresh `30s`.

The dashboard `uid` is `loopctl-scale-metrics` and it is tagged
`loopctl`, `scale`, `knowledge`, `us-27.15`.

## Prometheus metric names (how they are derived)

`telemetry_metrics_prometheus_core`'s exporter builds each Prometheus name by joining the
`Telemetry.Metrics` name segments with `_` (`Enum.join(name, "_")`, then stripping any
non-`[a-zA-Z0-9_]`). A `counter` exports as a Prometheus **counter** (name **as-is — no
`_total` suffix** in this library version, `telemetry_metrics_prometheus` 1.1.0 /
`_core` 1.2.1); a `distribution` exports as a **histogram** with cumulative
`_bucket{le="..."}` + `_sum` + `_count` series. Tags become labels (sorted). So:

| Telemetry.Metrics name | Prometheus series | Labels |
| --- | --- | --- |
| `loopctl.db.error.count` (counter) | `loopctl_db_error_count` | `endpoint`, `mapped_code`, *(cap-gated)* `tenant_id` |
| `loopctl.heavy_read_repo.query.duration` (distribution) | `loopctl_heavy_read_repo_query_duration_bucket` / `_sum` / `_count` | `endpoint`, plus `le` on `_bucket` |
| `loopctl.knowledge.vector_search.under_fill.count` (counter) | `loopctl_knowledge_vector_search_under_fill_count` | `endpoint`, *(cap-gated)* `tenant_id` |

Histogram buckets are in **milliseconds** (`unit: {:native, :millisecond}`):
`10, 50, 100, 250, 500, 1000, 2500, 5000, 10000` plus a `+Inf` overflow bucket. Because the
unit is ms, `histogram_quantile(...)` returns **ms** directly — the latency panels are in ms.

> **Cap-gated `tenant_id` (AC-27.15.3).** `tenant_id` is a real label on the two counters
> only while total tenants ≤ `:metrics_tenant_label_cap` (default 1000). Above the cap it
> collapses to the sentinel value **`_aggregated`** (cardinality 1). It is **never** a
> histogram label. None of the dashboard PromQL groups by `tenant_id`, so it is correct in
> both regimes; per-tenant drill-down falls back to the 7-day logs (which still carry
> `tenant_id`) — see `knowledge-scale.md`.

## The panels

### Row 1 — DB statement-timeout / errors

- **DB error rate by mapped_code** (timeseries, ops = per-sec):
  `sum(rate(loopctl_db_error_count[5m])) by (mapped_code)`. The
  **`db_statement_timeout`** series (SQLSTATE **57014**) is forced red/bold — it is the one
  that signals heavy reads giving up under load. Siblings (serialization / deadlock /
  catch-all) are context.
- **Statement-timeout rate (57014)** (stat):
  `sum(rate(loopctl_db_error_count{mapped_code="db_statement_timeout"}[5m]))`. Red at
  **0.083/s = 5 timeouts/min**, matching the ScaleAlerts `:scale_alert_timeout_rate_per_min`
  default that fires the in-app webhook.

> A query that **times out never records a latency sample** — it raises before `total_time`
> is emitted — so it appears **here**, not in the heavy-read histogram. Expect a healthy p95
> while timeouts climb; that split is by design (the counter is the "gave up" signal, the
> histogram the "slow but completed" signal).

### Row 2 — Heavy-read latency

- **Latency quantiles p50 / p95 / p99** (timeseries, ms):
  `histogram_quantile(0.50|0.95|0.99, sum(rate(loopctl_heavy_read_repo_query_duration_bucket[5m])) by (le))`.
  A red **threshold line at 2000 ms** marks the sub-2s heavy-read SLO the
  `HEAVY_READ_POOL` is sized for (US-27.11) and the ScaleAlerts `:scale_alert_p95_latency_ms`
  default. **The threshold that matters: p95 crossing 2000 ms.**
- **Latency distribution** (heatmap): `sum(rate(loopctl_heavy_read_repo_query_duration_bucket[5m])) by (le)`
  with query format **Heatmap** — shows the distribution shifting toward the
  2500/5000/10000 ms buckets before p95 crosses the line.

### Row 3 — Recall under-fill

- **Under-fill rate by endpoint** (timeseries, ops):
  `sum(rate(loopctl_knowledge_vector_search_under_fill_count[5m])) by (endpoint)`. Red
  threshold line at **0.5/s = 30 events/min** (ScaleAlerts
  `:scale_alert_under_fill_rate_per_min` default). Source: US-27.6b (a densely-linked hub
  hiding above-threshold neighbors).
- **Total under-fill rate** (stat): the all-endpoint sum, same 0.5/s red threshold.

## Alerting is NOT in this dashboard

`fly-metrics.net`'s managed Grafana has **alerting disabled** (per Fly: *"Fly.io doesn't
include built-in alerting on metrics, so you'll need to set up alerting yourself against the
Prometheus endpoint."*). The PromQL above therefore **visualizes only — nothing fires from
it**.

The **firing** path (US-27.15 AC-27.15.2) is a self-contained, loopctl-owned threshold
checker: **[`Loopctl.Telemetry.ScaleAlerts`](../../lib/loopctl/telemetry/scale_alerts.ex)**.
It windows the same three signals via atomic ETS counters, evaluates them on a timer
(`:scale_alert_check_interval_ms`, default 60 s), and on an **edge-triggered** breach POSTs
an id-only JSON payload to `:scale_alert_webhook_url` (Slack / PagerDuty / generic). Its
thresholds are the SAME numbers the dashboard draws (5 timeouts/min, p95 2000 ms, 30
under-fills/min). Enable it in prod by setting `SCALE_ALERT_WEBHOOK_URL`; full config table
in [`knowledge-scale.md`](../runbooks/knowledge-scale.md#the-firing-alert-path-loopctltelemetryscalealerts).

The dashboard is for a human watching the trend; ScaleAlerts is the thing that pages.

## Assumptions a reviewer / importer should check

- **Datasource.** The dashboard binds a Prometheus datasource via the `datasource` template
  variable at import time — pick the Fly managed-Prometheus datasource. No uid is hard-coded.
- **Metric presence.** Series only exist once the reporter has been scraped in an env where
  `:metrics_reporter_enabled` is true (prod) and the underlying events have fired. On a quiet
  window `rate(...)` and `histogram_quantile(...)` legitimately return empty/NaN.
- **Histogram unit is ms**, not seconds — the quantile panels and the 2000 ms line are ms.
- **Heatmap format.** If the heatmap renders empty, confirm the query's **Format = Heatmap**
  and that the datasource returns the `le`-labelled `_bucket` series (Grafana ≥ 9).
- **No `_total` suffix.** This library version exports counters without the Prometheus
  `_total` convention — the names above are literal. If the reporter dep is ever upgraded to
  one that appends `_total`, update the four counter expressions here and in
  `knowledge-scale.md`.
- **Bucket layout.** Buckets are the ms set above; if `reporter_options[:buckets]` in
  `scale_metrics.ex` changes, the heatmap y-axis and the histogram_quantile accuracy shift
  accordingly (the PromQL itself stays correct).
