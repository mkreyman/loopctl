# Runbook: Memory-promotion pipeline metrics (Epic 29 / US-29.2)

Observability for the **auto-promotion** pipeline that compiles session turns into
durable `:promoted` long-term memories (see
[`docs/agent-memory.md` § Promotion lifecycle](../agent-memory.md#promotion-lifecycle-epic-29--part-2)).
Because promotion runs **unattended** — an hourly cron sweep plus an optional Claude
Code Stop hook (`mkreyman/claude-config#85`) — a sweep that silently fails, gets
budget-walled, or degrades every tick must be VISIBLE in metrics rather than a
mystery. Every stage emits a `:telemetry` event so it is.

## The telemetry events

All events are `[:loopctl, :memory_promotion, <event>]` via
[`Loopctl.Memory.PromotionTelemetry`](../../lib/loopctl/memory/promotion_telemetry.ex),
emitted by `Loopctl.Memory` (budget refusals), the per-session
[`Loopctl.Workers.MemoryPromotionWorker`](../../lib/loopctl/workers/memory_promotion_worker.ex),
and the cron [`Loopctl.Workers.MemoryPromotionSweepWorker`](../../lib/loopctl/workers/memory_promotion_sweep_worker.ex).
Every event's `metadata` carries `%{tenant_id, subject_id, session_id}` (the sweep's
`:swept` carries `%{tenant_id}`), so metrics can be sliced per tenant.

| Event | Measurements | Meaning / what it tells you |
|-------|--------------|------------------------------|
| `:swept` | `%{sessions, enqueued}` | A sweep tick enumerated candidate sessions and enqueued up to the per-tick cap. `enqueued == 0` across ticks while sessions exist ⇒ the pipeline is stalled. |
| `:skipped` | `%{count}` | A session was watermark-unchanged (or a 0/1-turn no-op) and NOT re-compiled — the idempotency spine at work (no LLM spend). |
| `:compiled` | `%{candidates}` | A session was compiled; `candidates` survived the confidence gate. |
| `:gated_out` | `%{count}` | Candidates dropped at write as exact `embedding_content_hash` duplicates. |
| `:promoted` | `%{count}` | Fresh `:promoted` memories written. |
| `:superseded` | `%{count}` | Near-dup supersedes (new row live, prior `:promoted` row `superseded_by`-hidden). |
| `:degraded` | `%{count}` | Recall/embedding degraded mid-run → the job snoozed; NO watermark advance, retried when healthy. |
| `:quota_exceeded` | `%{count, dropped}` | Subject hit its hard live-memory cap; run terminally discarded. `dropped` = compiled survivors that could not be written (loss is visible, not silent). |
| `:budget_exceeded` | `%{count}` | Tenant hit its compiles/hour cap; refused **pre-LLM** (no BYO-key spend). |
| `:failed` | `%{count}` (metadata `:stage` = `:compile` \| `:persist`) | A compile/LLM or persist/write failure — retryable, and NOW OBSERVABLE. A steady stream keyed to one tenant ⇒ a bad BYO key / provider outage. |
| `:eval` | `%{precision, recall, ...}` | Promotion-compile QUALITY snapshot (US-29.5) — calibration only, never gates. See [promotion-eval.md](promotion-eval.md). |

## What to chart / alert on

- **Throughput** — `sum(:promoted) + sum(:superseded)` per tenant/day: how much durable
  memory the pipeline is producing. A drop to zero while `:swept.sessions > 0` and
  `:skipped` is not saturating ⇒ investigate.
- **Failure rate** — `rate(:failed)` per tenant. A non-transient rate (esp. `stage:
  :compile`) is the canonical "a tenant's promotion is silently broken" signal — alert
  on it. This is the AC-29.2.11 guarantee: a failing sweep is never silent.
- **Budget saturation** — `rate(:budget_exceeded)` per tenant: the tenant is hitting its
  compiles/hour cap; sessions defer to later ticks (no spend, but promotion lags). A
  sustained rate may warrant a budget review.
- **Degradation** — `rate(:degraded)`: embeddings are down; runs are snoozing and
  re-attempting. Correlate with the embedding-provider health.
- **Quota** — `sum(:quota_exceeded.dropped)`: durable facts lost because subjects are at
  their memory cap. Persistent nonzero ⇒ subjects need pruning or a higher cap.

Attach `Telemetry.Metrics` `counter`/`sum`/`last_value` handlers on these events (the
same reporter path as the eval metric) to feed a dashboard or alerting.

## Honest caveats

- **`:skipped` dominates a healthy steady state.** Once sessions are watermarked, most
  ticks skip — that is the idempotency spine working, not inactivity. Judge health by
  `:failed`/`:budget_exceeded`/`:degraded`, not by a high `:skipped`.
- **Budget refusals are not errors.** A `:budget_exceeded` (429) is the system correctly
  bounding BYO-key spend; it is a lag signal, not a failure. Only `:failed` is a genuine
  error axis.
- **Counts are per-emit, not deduped.** A session retried across attempts can emit
  `:failed` more than once; alert on RATE, not a single event.
