# Embedding side-table cutover (US-41.1)

The per-tenant embedding **dimension** feature moves vectors off the fixed-width
`articles.embedding` / `memories.embedding` columns (`vector(1536)`) and onto the
dimension-tagged `article_embeddings` / `memory_embeddings` side tables. This runbook
is the operator surface for the cutover; the design lives in the `Loopctl.Embeddings`
moduledoc.

## Order (AC-41.1.8)

The read flag may only be flipped after the dual-write code has reached **every**
node — during a rolling deploy an old node writes only the legacy column, so a node
reading the side table would miss its writes.

1. **Deploy** the dual-write code to every node.
2. **Backfill** the legacy vectors into the side table (idempotent, resumable):

       mix loopctl.embeddings backfill

3. **Reconcile** the crash-window gap and `live_denorm` drift. The standing hourly
   `Loopctl.Workers.EmbeddingReconciliationWorker` also does this automatically, but
   run it once by hand to confirm a clean sweep before the flip:

       mix loopctl.embeddings reconcile
       mix loopctl.embeddings status   # expect all gap/drift counts at 0

4. **Cut over** the read flag (a single `system_configs` UPDATE, no redeploy):

       mix loopctl.embeddings cutover

## Reverting

The flag is a `SystemConfig` integer precisely so the revert is a single UPDATE with
no redeploy, supported for the whole dual-write window:

    mix loopctl.embeddings revert

## Standing reconciliation

`Loopctl.Workers.EmbeddingReconciliationWorker` runs from the Oban crontab (hourly,
`mode: all_tenants`). It sweeps two classes of drift that are otherwise permanent
recall blackouts found only by a manual IEx call:

- the **dual-write crash window** — a legacy row without its dim-1536 side-table
  mirror;
- the **active-dimension gap** — a parent row with a side-table row at some dimension
  but none at the tenant's active dimension (the window where a write races
  `complete_reembed`'s stale-dimension sweep). It re-enqueues the ordinary embedding
  workers to re-embed those rows at the active dimension.

## Re-embed onto a new dimension (AC-41.1.10)

A tenant moving to a model with a different native dimension triggers a re-embed via
`POST /api/v1/knowledge/embeddings/reembed` (orchestrator+; audited on enqueue and on
completion). Recall keeps serving at the current dimension for the whole run; the
tenant's recorded dimension flips and the stale-dimension rows drop only after the
whole corpus (articles, per-tenant system-article materializations and agent
memories) is present at the target.
