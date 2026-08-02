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
| `hnsw.ef_search` (query recall breadth) | implicit default 40, only raisable via `ALTER ROLE` | **live-tunable** `SystemConfig "hnsw_ef_search"` = 40, applied per-ANN-read via `SET LOCAL` **only when non-default** (`ALTER ROLE` still honored at the default) | none (value unchanged) |
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
  pgvector-ANN endpoints only (`HeavyRead.ann_endpoints/0` — `suggested_links`,
  `semantic_search`, `novelty`, `vector_search`, `memory_recall`). The `distant_pairs` /
  `distant_pairs_bridge` self-joins are **excluded**: they are column-to-column
  (`a.embedding <=> b.embedding`) with no `$const` target, so pgvector's HNSW index — and
  thus `hnsw.ef_search` — cannot apply (the `Loopctl.Knowledge.CosineLintExceptions`
  registry records this "no $const target, HNSW N/A" invariant for `do_distant_pairs/7`).
  The `SET LOCAL` is emitted **only when the configured value differs from the pgvector
  default** (see the precedence contract below), so at the default no ANN GUC round-trip
  occurs at all.

### `SystemConfig` vs `ALTER ROLE` precedence (US-38.4 review fix)

An unconditional per-read `SET LOCAL hnsw.ef_search = 40` would silently **shadow** a
role-level `ALTER ROLE <role> SET hnsw.ef_search = N` — `SET LOCAL` overrides any
role/session default for its transaction — regressing recall for an operator who raised
it via the historically-documented (US-27.11/27.13) `ALTER ROLE` lever. The emission is
therefore gated: `maybe_put_ef_search/2` attaches `:hnsw_ef_search` (→ the `SET LOCAL`)
**only when `hnsw_ef_search/0` differs from the pgvector default 40**. Resulting contract:

| `SystemConfig hnsw_ef_search` | Per-read `SET LOCAL`? | Effective `ef_search` on an ANN read |
|-------------------------------|-----------------------|--------------------------------------|
| 40 (default)                  | no                    | the session/role default → `ALTER ROLE` value if set, else 40 |
| non-default (e.g. 100)        | `SET LOCAL … = 100`   | 100 (SET LOCAL wins over any role default) |

So `SystemConfig` is the live, no-redeploy **fleet-wide** override; `ALTER ROLE` is a
role-scoped default that is honored whenever `SystemConfig` is left at 40. (Edge case: to
force ANN reads to exactly 40 while a higher `ALTER ROLE` default exists, lower the role
default — `SystemConfig = 40` is treated as "no override".)

### Live-pool verification of `SET LOCAL hnsw.ef_search` (US-38.4 review fix)

The `statement_timeout` `SET LOCAL` was recorded as "verified to enforce against the live
pool"; the same evidence is now recorded for the `hnsw.ef_search` `SET LOCAL`:

- **Mechanism equivalence (structural).** `hnsw.ef_search` is set by the **same in-transaction
  `SET LOCAL`** path as `statement_timeout` (`run_timed_transaction/4`: `BEGIN; SET LOCAL
  statement_timeout; SET LOCAL hnsw.ef_search; SELECT; COMMIT`). pgbouncer's startup-parameter
  allowlist — the US-27.13 outage's root cause — applies ONLY to connection **startup**
  parameters, NOT to in-transaction `SET` commands, which pass through transparently under both
  transaction and session pooling. So the US-27.13 failure mode (a rejected startup parameter
  crash-looping the pool) is **structurally out of scope** for a `SET LOCAL`, exactly as it is
  for the already-live-verified `statement_timeout` `SET LOCAL`.
- **Round-trip evidence (real Postgres + pgvector, through the pooled heavy-read repo).**
  Confirmed via `Loopctl.HeavyRead.repo()` (the pooled repo): inside a transaction,
  `SET LOCAL hnsw.ef_search = 123` succeeds and `SHOW hnsw.ef_search` returns `"123"`; after
  `COMMIT` the value resets (a fresh checkout does not carry it). This holds even though
  `hnsw.ef_search` is a **namespaced (dotted) placeholder** GUC that Postgres accepts a `SET`
  for before the extension's shared library has registered it in the backend — the
  pgvector-documented order the code relies on. The heavy-read test suite exercises the same
  path (`heavy_read_test.exs` — an ANN read issues `SET LOCAL hnsw.ef_search` against real
  Postgres; the pin asserts the emitted value).
- **Live fly-mpg confirmation (operator step, tied to the runbook).** Under the precedence
  contract above, prod at the default 40 issues **no** `SET LOCAL hnsw.ef_search` — the
  managed-PG assumption is only exercised once an operator raises the knob. The recall-lever
  section of `docs/runbooks/knowledge-scale.md` makes that raise step include the live
  `SET LOCAL … ; SHOW hnsw.ef_search` confirmation through the fly-mpg heavy-read pool (inside
  a transaction), so the first non-default use IS the recorded live round-trip check before
  reliance.

### `hnsw.iterative_scan` — the FILTERED-recall lever (#488 / #491)

`ef_search` widens the index walk; it does not fix a **residual-filter** under-return. A
tenant-filtered (or dimension-/category-/status-filtered) ANN applies those predicates
AFTER the index walk, so on a shared HNSW index the whole `ef_search` candidate window can
belong to other tenants and the query returns **zero** rows that pass the filter. pgvector
**>= 0.8**'s `hnsw.iterative_scan` resumes the walk until the `LIMIT` is satisfied or
`hnsw.max_scan_tuples` is reached.

Design points (`Loopctl.HeavyRead.hnsw_iterative_scan/0`, `hnsw_max_scan_tuples/0`):

| `SystemConfig hnsw_iterative_scan` | emitted |
|---|---|
| `0` — explicit, unrecognized, or the MISSING-row fallback (`default_iterative_scan_code/0`: shipped `0`, **test `1`**) | nothing — no `SET LOCAL`, no capability probe |
| `1` | `SET LOCAL hnsw.iterative_scan = relaxed_order` (+ `hnsw.max_scan_tuples`) |
| `2` | `SET LOCAL hnsw.iterative_scan = strict_order` (+ `hnsw.max_scan_tuples`) |

- **Single source of truth at RUNTIME.** `SystemConfig` only. No `Application`-level override
  may be set in any NON-test config — `config_embedding_read_path_test.exs` fails the build
  on one — because an env pin would shadow the operator lever in prod. Tests that need a
  specific mode prime the `SystemConfig` cache explicitly in an `async: false` module.
- **The test env IS pinned, and that is not a contradiction of the line above.**
  `config/test.exs` sets `:hnsw_iterative_scan_default` to `1`. An earlier revision of this
  section said no override existed anywhere and that CI exercised the shipped `0`; both were
  false once the pin landed, and the guard test it cites bars the key only outside test.
  The pin exists because leaving test unpinned made CI assert exact recall against a
  configuration **nobody runs**: the ANN applies `tenant_id` as a post-index residual, so a
  tenant whose rows fall outside the global top-`ef_search` batch is silently dropped and the
  read returns `[]`. That is the long-running side-table flake (3 failing runs / 23 before the
  pin, 0 / 25 after; four earlier "recall" fixes never touched the mechanism). Under-return
  coverage of the OFF path is asserted directly against `HeavyRead.opts/1` in
  `test/loopctl/heavy_read_hnsw_ef_search_test.exs` instead, where the OFF decision actually
  lives.
- **Ships OFF; prod runs ON.** The shipped `@default_hnsw_iterative_scan` is `0`, so a fresh
  install makes no latency-for-recall trade it did not ask for. The `loopctl` production
  deployment has the operator-set row at `1` (relaxed_order) since #488, verified against the
  live app 2026-08-01. The test pin matches PROD, not the shipped default — three values, on
  purpose. Whether the shipped default should move to `1` is an open operator decision and is
  deliberately not settled in code; raise it as its own change with a benchmark.
- **Fail-closed, non-poisoning capability probe.** `iterative_scan_supported?/0` reads
  `pg_extension` on the SAME repo the ANN read uses (`HeavyRead.repo/0`, under
  `@probe_timeout_ms` — 500ms TOTAL, which bounds the pre-gate CHECKOUT, not just the query,
  and is split in half across the probe's two attempts (a refused `mode: :savepoint`, then the
  plain retry), so a saturated pool goes inconclusive fast instead of queueing ahead of the
  shed) and caches the answer in `:persistent_term` **with a TTL**. An old extension →
  `false` + a warning naming the detected version; an ABSENT extension gets its own distinct
  warning (it is not a version problem). Either way the setting is a silent no-op, NOT a
  raise: nothing is emitted, so the ANN read is unaffected. Errors AND exits (`:noproc`, a
  wedged-pool `{:timeout, _}`) are both caught. An INCONCLUSIVE probe (pool timeout, DB blip)
  is negative-cached for only 60s — short enough that a transient failure cannot pin the lever
  off VM-wide until a redeploy, bounded enough that a degraded backend costs one probe + one
  log line per minute rather than one per ANN read. The CONCLUSIVE verdict also expires
  (10 min), so a replica failover onto an older pgvector self-heals instead of 500-ing every
  ANN read with a GUC the new backend rejects.
- **Cost.** The mode string is looked up from a fixed table, so the value interpolated into
  the `SET LOCAL` is always one of three literals — never operator text. The extra GUCs ride
  the existing short heavy-read transaction (no new checkout). Filtered-query latency rises
  by construction; `hnsw_max_scan_tuples` (clamped `[1, 1_000_000]`, pgvector default 20000)
  is the bound.

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
test asserts the emitted DDL carries the configured `WITH (...)`, and `heavy_read_test.exs`
asserts the ANN read path issues `SET LOCAL hnsw.ef_search = N` for a NON-default
`SystemConfig` value, issues NONE at the default (so a role-level `ALTER ROLE` default is
not shadowed), and that `hnsw_ef_search/0` clamps an out-of-range value into `[1, 1000]`.

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
