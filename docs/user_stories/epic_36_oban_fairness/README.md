# Epic 36 — Per-Tenant Oban Fairness & Queue Topology

Remediation of GitHub issue **#351** (roadmap Epic 4, tracked **#355**) — the
classic noisy-neighbor failure at loopctl's target scale: one tenant's bulk
ingest monopolizes the shared `:embeddings` / `:knowledge` queues and starves
every other tenant.

## Decision: stock-Oban fallback (Mark, 2026-07-14)

#351's target architecture recommends **Oban Pro** (Smart engine `global_limit` +
`partition: [args: [:tenant_id]]`). loopctl runs **stock Oban 2.19 (Basic
engine)** and Oban Pro is a **paid Enterprise dependency** (volume-priced,
NDA/procurement). Mark chose the **stock-Oban fallback (full)**: build fairness in
app code, no new dependency, keep per-node fairness for now, and **revisit Oban
Pro at Epic 38 (#353, horizontal scaling)** when cluster-global limits actually
matter (Pro's `global_limit` is cluster-global; the app-level gate here is
per-node, which is sufficient until loopctl runs multiple nodes).

## Scope reconciliation (verified against `master` before authoring)

| #351 finding | Status | Evidence |
|--------------|--------|----------|
| Queue widths hardcoded, not in runtime.exs | ✅ done | US-32.2 — `Loopctl.ObanConfig.queues()`, `OBAN_QUEUE_*` env vars (`oban_config.ex:52-95`) |
| No Oban queue/orphan observability | ✅ done | US-34.1/34.2 — `oban_metrics_poll_*` gauges, orphan health threshold, Reindexer |
| Per-node vs global concurrency limit | ⏸ deferred to Epic 38 | `global_limit` is Oban Pro-only; per-node fairness is sufficient pre-multi-node |
| **No per-tenant fairness anywhere** | ❌ open | none — `oban_config.ex:7` calls itself "the substrate for Epic 4 fairness (#351)" |
| **Head-of-line blocking:** 6-min LLM ingestion shares 5-wide `:knowledge` with sub-second linking/lint/MOC/metrics | ❌ open | `content_ingestion_worker.ex:36 queue: :knowledge` |
| **Unbounded per-tenant fan-out** (N items → N ingest → N embed → N linking, uncapped) | ❌ open | `content_ingestion_worker.ex:829,885`; `article_embedding_worker.ex:127` |
| **`:embeddings`→`:knowledge` coupling** (a completed embedding enqueues a linking burst back onto `:knowledge`) | ❌ open | `article_embedding_worker.ex:167-172` |
| **No batch-ingest backpressure** (enqueues unconditionally) | ❌ open | `knowledge_ingestion_controller.ex:395` |
| **Per-job `count(*)`** in linking hot path | ❌ open | `article_linking_worker.ex:225-242` |
| **Dead `:verification` queue** (declared on a worker but not in the queues list → those jobs never run) | ❌ open (latent bug surfaced during grounding) | `verification_runner_worker.ex:10 queue: :verification`; not in `@default_queues` |

## Stories

| Story | Title | Depends |
|-------|-------|---------|
| US-36.1 | Queue topology: dedicated `:ingestion` queue for long LLM jobs + register the dead `:verification` queue (env-driven widths) | — |
| US-36.2 | Per-tenant in-flight fair-share gate on the contended queues (Basic-engine snooze/defer — no tenant holds more than K of N slots) | US-36.1 |
| US-36.3 | Batch-ingest backpressure: `429` when a tenant's in-flight ingestion backlog exceeds a threshold | US-36.2 |
| US-36.4 | Linking hot-path efficiency: batched `insert_all` + `on_conflict`; replace per-job `count(*)` with a sampled telemetry count | US-36.1 |

## Non-negotiable constraints (system is LIVE)

- **Fairness is a target, not a hard invariant.** The Basic engine has no native
  partitioning; the mechanism is cooperative (a worker yields via `{:snooze, n}`
  when its tenant is over fair share, plus a bounded pre-enqueue check). A job is
  **never dropped or lost** — worst case it's delayed. Tests assert the
  *fairness outcome* (a flooding tenant does not starve others), not an exact
  slot count at an instant (avoid the Mox/parallel-suite flake class —
  assert the outcome class, per prior lessons).
- Any new index on the hot `oban_jobs` table is **online** (`CONCURRENTLY`,
  `@disable_ddl_transaction`) and justified — prefer to avoid one; if the
  fair-share count needs it, it's a partial/expression index on
  `(queue, state, (args->>'tenant_id'))` and its cost is measured.
- Queue widths and per-tenant caps/thresholds are **env-driven** (extend
  `Loopctl.ObanConfig`, config-based DI) so ops can tune during an incident with
  `fly secrets set … && restart` — **no deploy**. **Never set a secret to a doc
  placeholder** (see the STH_SWEEP_CRON incident, epic_35).
- Moving `ContentIngestionWorker` to `:ingestion` must preserve total pool
  budget (don't blow past the DB connection budget — the new queue's width comes
  out of / is sized against the existing budget, not added on top blindly).
- Backpressure returns a **429 with a `Retry-After`** and does not lose the
  caller's intent; it must not break existing batch-ingest clients that stay
  under the threshold (existing-behavior test).
- Every merge is smoke-gated with a `knowledge_count` / ingestion-health check
  either side, and **the master Deploy + Post-deploy Smoke jobs are watched to
  green** (runtime.exs env-var changes only fail at release boot — epic_35 lesson).
