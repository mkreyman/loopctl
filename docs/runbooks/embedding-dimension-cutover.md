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

**Read this before reverting — since GH #578 a revert is an INCIDENT action, not a
routine toggle.** The flag is still a `SystemConfig` integer, so the flip itself is a
single UPDATE with no redeploy, and the `articles.embedding` COLUMN is still
dual-written, so the legacy read path is still CORRECT. What changed is its cost:
migration `20260805120000_drop_legacy_articles_embedding_hnsw_index.exs` retires
`articles_embedding_hnsw_idx` on any install whose `embedding_side_table_reads` is
already `1` — i.e. on exactly the installs that can reach a revert.

With that index gone, flipping back to `0` puts every semantic read on an UNINDEXED
column: a seq scan + top-N sort that trips the heavy-read `statement_timeout`. The
cancel surfaces as `504 db_statement_timeout` — **not** `503`/`heavy_read_overloaded`,
which only the per-tenant concurrency shed produces, and which is the only thing the
labelled keyword degrade matches. There is no graceful fall-back on that path today:
semantic search returns no results tenant-wide.

So, in order:

1. **Check whether the legacy ANN index is still there** — by capability, never by
   name (the retirement and a broken deploy are indistinguishable to a name check):

       SELECT idx.relname, i.indisvalid
       FROM pg_index i
       JOIN pg_class idx ON idx.oid = i.indexrelid
       JOIN pg_class tbl ON tbl.oid = i.indrelid
       JOIN pg_am am ON am.oid = idx.relam
       JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
       WHERE tbl.relname = 'articles' AND a.attname = 'embedding' AND am.amname = 'hnsw';

   `mix loopctl.embeddings status` reports the same thing as
   `legacy articles.embedding HNSW index:`.

2. **If it is absent, rebuild it FIRST.** Raise `maintenance_work_mem` well above the
   64 MB default or the ~657 MB HNSW build silently falls back to the slow on-disk
   path. Use the same `WITH` parameters every other HNSW index is built with
   (`Loopctl.Repo.HnswIndex.with_params_clause/0` — `m = 16, ef_construction = 64`
   unless the instance overrides `:hnsw_m` / `:hnsw_ef_construction`):

       SET maintenance_work_mem = '2GB';
       CREATE INDEX CONCURRENTLY articles_embedding_hnsw_idx
         ON articles USING hnsw (embedding vector_cosine_ops)
         WITH (m = 16, ef_construction = 64);

   Prefer this explicit `CREATE INDEX` over rolling the migration back: Ecto's `:to`
   is INCLUSIVE, so `Loopctl.Release.rollback(20260805120000)` reverts every migration
   at or after that version, and it leaves the migration PENDING so the next deploy
   re-drops what you just rebuilt.

3. **Then revert the flag:**

       mix loopctl.embeddings revert

   The task performs check (1) itself and REFUSES while the index is absent, printing
   the rebuild above. `mix loopctl.embeddings revert --force` overrides that refusal —
   take it only when a slow-or-dead legacy path is deliberately preferable to the
   side-table one, and expect semantic search to be down until the rebuild lands.

The `memories` legacy indexes are untouched, so a memory-recall revert carries none
of this.

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
