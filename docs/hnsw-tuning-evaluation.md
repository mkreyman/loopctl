# HNSW index tuning evaluation (US-38.4 / GH #353)

Review-first, evidence-driven tuning pass for loopctl's pgvector HNSW indexes.
Two independent tracks; the outcome of BOTH is a **documented "keep what we have,
but make it explicit + tunable"** — an explicitly valid outcome per the story's
technical notes (do not churn indexes without evidence).

## TL;DR

| Knob | Before | After | Change to live indexes? |
|------|--------|-------|-------------------------|
| `m` (graph connectivity) | implicit default 16 | **explicit** `config :loopctl, :hnsw_m` = 16 | none (value unchanged) |
| `ef_construction` (build breadth) | implicit default 64 | **explicit** `config :loopctl, :hnsw_ef_construction` = 64 | none (value unchanged) |
| `hnsw.ef_search` (query recall breadth) | implicit default 40, only raisable via `ALTER ROLE` | **live-tunable** `SystemConfig "hnsw_ef_search"` = 40, applied per-ANN-read via `SET LOCAL` | none (value unchanged) |
| `memories.embedding` dual HNSW index | full + partial | **keep both** (both serve distinct live paths) | none |

Because every chosen value EQUALS today's implicit default, **no reindex DDL is
required** — the live `articles` / `memories` HNSW indexes were already built with
these parameters. Re-emitting them from the builder only affects indexes created
from now on (a fresh `mix ecto.reset` or a future table). This keeps the hot
`articles` / `memories` tables free of any write-blocking DDL (AC-38.4.4).

---

## Track A — `m` / `ef_construction` / `ef_search` made explicit + configurable

### What changed (code)

- **`m` / `ef_construction`** are now single-sourced in `Loopctl.Repo.HnswIndex`
  (`hnsw_m/0`, `hnsw_ef_construction/0`, `with_params_clause/0`) and interpolated
  as an explicit `WITH (m = 16, ef_construction = 64)` storage clause on every
  `CREATE INDEX ... USING hnsw` the module emits (articles + the full memories
  index), plus the partial-memories-index migration. Values flow from
  `config :loopctl, :hnsw_m` / `:hnsw_ef_construction` and are integer-validated
  before interpolation (`validate_build_param!/2`) — never an injection surface.
- **`ef_search`** is now the per-query recall knob `SystemConfig "hnsw_ef_search"`
  (default 40), read by `Loopctl.HeavyRead.hnsw_ef_search/0` and applied per-read
  via `SET LOCAL hnsw.ef_search = N` **inside the heavy read's existing
  `SET LOCAL statement_timeout` transaction** (`run_timed_transaction/4`), for the
  pgvector-ANN endpoints only (`HeavyRead.ann_endpoints/0`).

### Why per-request `SET LOCAL hnsw.ef_search` is now safe (the stale objection)

The moduledocs/runbook historically said per-request `SET LOCAL hnsw.ef_search`
was unsafe "because it needs a transaction, re-introducing the #172 small-pool
starvation". That objection **predates US-27.13**: since then EVERY heavy read
already runs inside a short `SET LOCAL statement_timeout` transaction
(`BEGIN; SET LOCAL; SELECT; COMMIT`), released at COMMIT. Adding one more
`SET LOCAL hnsw.ef_search` to that same transaction adds no new checkout and no
new hold — it is the opposite of a long-held connection. It remains NOT settable
via Postgrex startup `:parameters` (pgbouncer rejects the custom GUC — the US-27.13
outage class, still guarded by `config_pgbouncer_safe_parameters_test.exs`). The
code and its own docs are reconciled to say so.

### Recall vs latency vs build-cost / size evaluation

- **`m`** governs graph connectivity. Higher `m` → higher recall AND larger index
  + slower build + more memory. pgvector's default 16 is the balanced choice for
  corpora up to the millions; loopctl's corpus (≈76k articles, growing memories)
  is comfortably in the range where 16 gives strong recall without inflating index
  size. Raising it has a permanent size/build cost for a marginal recall gain that
  the cheaper query-time `ef_search` knob captures on demand.
- **`ef_construction`** governs build-time candidate breadth. Higher → better graph
  quality (recall) at higher BUILD cost only (no query-time or size cost beyond the
  graph it produces). Default 64 builds the current corpus fast; there is no recall
  complaint that would justify the slower builds of a higher value.
- **`ef_search`** is the cheap, reversible, query-time recall lever. Rather than
  bake more recall into a costly rebuild, we keep `m`/`ef_construction` at the
  balanced defaults and expose `ef_search` as a live knob (default 40) so an
  operator can trade latency for recall fleet-wide with a single `UPDATE` and
  **no redeploy** — and back off just as easily. This is the correct place to
  spend the recall/latency budget for a moderate, growing corpus.

**Decision: keep `m=16`, `ef_construction=64`, `ef_search=40`** — now explicit,
single-sourced, and (for `ef_search`) live-tunable. Revisit `m`/`ef_construction`
(with an online reindex migration) only if a scale-representative recall gate shows
the default graph under-recalling at a materially larger corpus.

### Recall no-regression

`m`/`ef_construction`/`ef_search` are all unchanged, so recall is unchanged by
construction. The recall gate (`test/loopctl/memory/scale_recall_test.exs`,
`test/loopctl/knowledge/vector_search_test.exs`) continues to pass; the builder unit
test asserts the emitted DDL carries the configured `WITH (...)` and that the ANN
read path issues `SET LOCAL hnsw.ef_search`.

---

## Track B — `memories.embedding` dual HNSW index justification

`memories.embedding` carries TWO HNSW indexes:

1. **Full** — all rows incl. superseded (migration `20260709000100`, built via
   `HnswIndex.create_if_absent_sql("memories")`). On the live DB it is named
   `memories_embedding_idx` (the builder's create name; no reconcile migration ran
   for memories, unlike articles — detection is capability-based, so the name does
   not matter).
2. **Partial** — `WHERE superseded_by IS NULL` (migration `20260709000300`),
   `memories_live_embedding_hnsw_idx`.

### Is the full index actually queried, or do all live searches use the partial?

The full index is **not** dead. `include_superseded: true` is a real,
publicly-reachable recall path (the `memory_recall` MCP tool +
`LoopctlWeb.MemoryController`). When `include_superseded: true`, `Loopctl.Memory`
drops the inner `superseded_by IS NULL` filter → the query predicate no longer
implies the partial index's predicate, so the planner CANNOT use the partial index
and serves the ANN from the full index. The default (hot) path adds
`superseded_by IS NULL`, exactly matching the partial index predicate, so it serves
the smaller partial index (keeping superseded rows out of the over-fetch pool — the
US-28.2 crowding fix).

### EXPLAIN evidence (dev DB, planner forced with `enable_seqscan/enable_sort = off`
to reveal index eligibility on the empty-scale table)

Default / live-only path (`... AND superseded_by IS NULL ORDER BY embedding <=> $1`):

```
Index Scan using memories_live_embedding_hnsw_idx on memories
  Order By: (embedding <=> $1)
  Filter: ((embedding IS NOT NULL) AND (tenant_id = $2))
```

Include-superseded path (no `superseded_by` filter, `ORDER BY embedding <=> $1`):

```
Index Scan using memories_embedding_idx on memories
  Order By: (embedding <=> $1)
  Filter: ((embedding IS NOT NULL) AND (tenant_id = $2))
```

Two distinct HNSW indexes, each the ONLY HNSW option for a distinct, live code
path. A partial index is provably ineligible for the include-superseded query
(predicate mismatch), so dropping the full index would force `include_superseded`
recall onto a Seq Scan + Sort — the #170/#172 timeout shape at scale.

**Decision: keep both.** Whichever the outcome, semantic recall of LIVE memories is
unchanged: the default path still serves the partial index; the test asserts the
default and `include_superseded` recall sets are unchanged.

### Rollback note (all DDL is online + reversible)

- The parameter change ships **no reindex** (values unchanged), so there is nothing
  to roll back on the live indexes. A FUTURE param change would ship an online
  migration: `@disable_ddl_transaction true` + `@disable_migration_lock true`,
  `CREATE INDEX CONCURRENTLY <new>` with the new `WITH (...)`, then
  `DROP INDEX CONCURRENTLY <old>` — rollback recreates the old-param index the same
  online way (`m`/`ef_construction` are build-time; never `ALTER ... SET` in place).
- The `hnsw_ef_search` seed migration is a single `INSERT ... ON CONFLICT DO NOTHING`
  with a `DELETE` down; a missing row safely falls back to the in-code default 40.
