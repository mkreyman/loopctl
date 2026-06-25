# Runbook: Knowledge subsystem scale & connection pools

> Seeded by US-27.11 (Theme 4). US-27.5 (the full scale runbook) will absorb and
> expand this. Operators: keep the **live verification** steps current.

## Connection pools (US-27.11)

loopctl runs three Ecto pools against the **same** managed Postgres database:

| Repo                     | Role        | Pool env var              | Default | Purpose                                                        |
| ------------------------ | ----------- | ------------------------- | ------- | -------------------------------------------------------------- |
| `Loopctl.Repo`           | RLS         | `POOL_SIZE`               | 10      | Tenant request path (RLS-enforced)                             |
| `Loopctl.AdminRepo`      | BYPASSRLS   | `ADMIN_POOL_SIZE`         | 3       | Light cross-tenant admin ops + writes + migrations             |
| `Loopctl.HeavyReadRepo`  | BYPASSRLS   | `HEAVY_READ_POOL_SIZE`    | 8       | Heavy vector/enumeration reads (search, suggest-links, pairs)  |

**Why a dedicated heavy-read pool:** heavy vector reads previously shared the
3-connection admin pool; three concurrent slow reads could monopolize all admin
capacity (this already distorted the #172 fix, which avoided a per-request
transaction to dodge starvation). Splitting them onto separate physical pools
removes that coupling and gives US-27.4/27.6b a clean pool-level lever.

### `HEAVY_READ_POOL_SIZE` (K) — sizing rationale (AC-27.11.1)

Default **8** supports **K ≈ 6** concurrent sub-2s heavy vector reads while
**reserving ~2 connections** for long-held **streamed-export** checkouts
(US-27.16), which hold a connection for *minutes* — a different profile than fast
reads. Raise it if export concurrency or heavy-read QPS grows, but only after
re-checking the connection budget below.

### Connection budget vs. `max_connections` (AC-27.11.5)

Per node: `10 + 3 + 8 = 21`. **Peak** during a rolling deploy (fly replaces one
machine at a time, so old + new briefly overlap) at 2 app nodes:
`42 (steady) + 21 (overlap node) + 2 (Oban notifier, 1/node) + 2 (fixed: migration +
console)` = **67** < 100 at 2 nodes (3-node ceiling peak = 89). Ceiling: **3 app
nodes** (`DbCapacity.max_supported_nodes`). Encoded in `Loopctl.DbCapacity`; asserted
by `db_capacity_test.exs`, and checked at **boot** against the ACTUAL runtime pool
sizes + live `max_connections` by `DbCapacity.warn_if_over_budget/0` (logs a warning
if exceeded). **If you scale past 3 machines or raise any pool size, the budget no
longer fits — re-derive it and resize the DB plan first.** The deploy strategy is
pinned to `rolling` in `fly.toml`; `bluegreen` would double the fleet's connections
and blow the budget.

**Live value (re-verify post-deploy and after any DB-plan resize):**

```sh
fly ssh console -a loopctl -C "/app/bin/loopctl rpc 'IO.inspect(Loopctl.AdminRepo.query!(\"SHOW max_connections\").rows)'"
```

Last verified: **2026-06-24 → `max_connections = 100`** (2-node peak 67 fits with
headroom). If you raise any pool size or node count, re-run the above and confirm
`Loopctl.DbCapacity.fits?(live_max, nodes)` stays true (the boot check logs a warning
otherwise).

## Server-side `statement_timeout` (US-27.11 → US-27.4)

`Loopctl.HeavyReadRepo` carries a **pool-level** `statement_timeout` via the repo
`:parameters` (a CORE GUC, settable in the startup packet — verified). Default
**10s**, override with `HEAVY_READ_STATEMENT_TIMEOUT_MS`. Every query on the heavy
pool fast-fails at this timeout (Postgres `57014`, surfaced as
`db_statement_timeout` by US-27.3) and releases the connection promptly — no
per-request transaction needed. So even a fully-saturated heavy pool self-drains
within `statement_timeout`.

Verify live:

```sh
fly ssh console -a loopctl -C "/app/bin/loopctl rpc 'IO.inspect(Loopctl.HeavyReadRepo.query!(\"SHOW statement_timeout\").rows)'"
```

> **Note for US-27.16 (streamed export):** a minutes-long export must NOT inherit
> the fast read timeout. Use `Loopctl.HeavyRead.transaction(fun, statement_timeout:
> ms)`, which issues `SET LOCAL statement_timeout = ms` scoped to that transaction
> (the stream must be enumerated INSIDE the transaction). A POSITIVE explicit bound
> is required — `0`/unlimited is rejected, so a runaway export can't pin a connection
> on the small heavy pool forever.

## Per-endpoint `statement_timeout` + slow-query logging (US-27.4)

**Default heavy-read timeout:** every heavy read runs under the pool-level
`statement_timeout` (`HEAVY_READ_STATEMENT_TIMEOUT_MS`, default 10s — see above). When
it fires, the request fast-fails as the structured **504 `db_statement_timeout`**
(US-27.3) and the connection is released promptly — no 30s hang, no per-request
transaction.

**Per-endpoint override (optional):** to give one endpoint a tighter (or looser) bound,
set `:heavy_read_statement_timeout_overrides` (ms) in config — keys
`:suggested_links`, `:semantic_search`, `:distant_pairs`, `:novelty`:

```elixir
config :loopctl, :heavy_read_statement_timeout_overrides, %{suggested_links: 5_000}
```

An override applies via `SET LOCAL` inside a transaction on the dedicated heavy pool
(justified by the 8-conn sizing); endpoints with no override use the pool default (no
transaction). Leave it empty unless an endpoint needs a different bound.

**Heavy-read endpoints** (those using `HeavyRead.all/one`): `:suggested_links`,
`:semantic_search`, `:distant_pairs`, `:novelty`, `:enumeration`. The enumeration endpoint
(`:knowledge_search_controller` list mode, `list_filtered/2`) now routes through HeavyRead to
inherit the pool-level statement_timeout and optional per-endpoint override (matching the other
four endpoints). Enumeration pages up to `limit: 1000` rows per request.

**Slow-query logging:** `Loopctl.Telemetry.SlowQueryLogger` (attached at boot) logs any
query slower than `:slow_query_threshold_ms` (default **1000**, tunable in config/env)
at `:warning` with `duration_ms`, `repo`, `source`, and the request `tenant_id` /
`request_id`. Raw SQL / params / vectors are never logged. The `endpoint` field is populated
only for the five `HeavyRead` endpoints (via `telemetry_options`); other repo queries log
`endpoint=` empty. Off-request callers (Oban workers, background tasks) log `tenant_id=`
and `request_id=` empty. Lower the threshold to surface a trend before it becomes an incident:

```elixir
config :loopctl, :slow_query_threshold_ms, 500
```

## Keyset pagination index (US-27.9a)

The article keyset cursor seeks on `(tenant_id, inserted_at, id)`, backed by
`articles_tenant_inserted_id_idx` (built `CREATE INDEX CONCURRENTLY`,
`@disable_ddl_transaction`).

**Plan profile by filter shape (verified at 80k, `keyset_plan_scale_test.exs`):**

| List query shape | Plan at prod scale | Cost profile |
| ---------------- | ------------------ | ------------ |
| no filter / `category=` (scalar) | Index Scan on the keyset btree, walked in order, **no Sort** | true keyset — O(page) per page |
| `tags=` (array `&&`) | **BitmapAnd**(tags GIN ∩ keyset btree) → Bitmap Heap Scan → **Sort** | bounded by **tag selectivity**, not corpus |

The array (`tags`) path Sorts because no btree can serve BOTH array containment
(needs GIN) AND `(inserted_at, id)` order. This is **expected and non-regressive** —
a tag-filtered *offset* query used the same GIN+Sort plan; the keyset version adds
drift-freedom on top. It is bounded by how many rows carry the tag (the GIN driver),
never a full-corpus Seq Scan. If a single tag ever grows to a large fraction of a
tenant's corpus and tag-filtered deep enumeration becomes hot, the lever is a
partial/covering index for that workload — not a change to the keyset mechanic.
The scale test enforces this: scalar shapes must stay strictly index-ordered
(`refute_full_scan`); the tags shape must avoid a Seq Scan and prove the selective
tags GIN drives the scan (`refute_seq_scan` + `assert_index_used` on the tags GIN).
It deliberately does NOT pin the BitmapAnd-with-keyset-btree shape — once the GIN cuts
the corpus to ~2% the planner may apply the cursor as a cheap heap filter, a
cost-marginal choice at the 80k floor that would make the gate flaky without catching
any real regression.

**Boot probe:** `Loopctl.IndexHealth.warn_if_invalid_indexes/0` runs at boot (prod)
and logs a WARNING + emits `[:loopctl, :index_health, :invalid]` telemetry if
`articles_tenant_inserted_id_idx` is missing or INVALID — so the recovery below is
triggered by an alert, not a latency incident. **Operational note:** if the concurrent build is
interrupted, Postgres can leave an **INVALID** index behind, and the migration's
`IF NOT EXISTS` re-run will NOT rebuild it (it sees the name and no-ops). The query
still returns correct rows (it degrades to a Seq Scan — slower, not wrong). Recovery
is manual: `DROP INDEX CONCURRENTLY IF EXISTS articles_tenant_inserted_id_idx;` then
re-run the migration. Verify validity after deploy:

```sql
SELECT indexrelid::regclass, indisvalid
FROM pg_index WHERE indexrelid = 'articles_tenant_inserted_id_idx'::regclass;
```

## Keyset pagination rolled onto by-tag / by-source / change-feed (US-27.9b)

US-27.9b applies the **same** US-27.9a keyset cursor (verbatim — one HMAC codec,
`Loopctl.KeysetCursor`, with a per-surface namespace) to the remaining enumeration
surfaces an agent uses to walk the KB. The original offset-drift incident (#175) was a
**by-TAG** walk (a tag count swung 9,881 → 4,981 mid-enumeration), so the cursor had to
reach these, not just the bare article list.

### Index dual-path ordering + the no-mixing rule

Both `GET /knowledge/index` and `GET /knowledge/search` (list mode) are **dual-path**:

- **`cursor` param ABSENT** → the legacy **offset** path, unchanged. Index orders by
  `category, updated_at DESC, id`; search-list by `updated_at DESC, id`. Emits
  `total_count`/`offset`, NOT `next_cursor`.
- **`cursor` param PRESENT** (even empty `cursor=`) → the **keyset** path, ordered
  `inserted_at ASC, id ASC`. Emits `next_cursor`/`has_more`/`count`, NOT `total_count`.

**Do NOT mix the two mid-enumeration** — the sort orders differ, so switching paths
between pages skips/repeats rows. Start with an empty `cursor=` and follow
`meta.next_cursor` verbatim to the end (`next_cursor: null`). The keyset path is the
drift-free way to walk a tag or a source to exhaustion under concurrent writes; the
offset path is retained only for back-compat.

### by-source index (`articles_tenant_source_inserted_id_idx`)

by-source (`?source_id=`) is a **selective scalar equality**. Unlike `category=` (which
the `(tenant_id, inserted_at, id)` btree already serves index-ordered with a cheap
recheck), a deep by-source page over the general keyset btree would heap-recheck
`source_id=` across the whole tenant corpus. So US-27.9b adds a dedicated **partial
composite** index:

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS articles_tenant_source_inserted_id_idx
ON articles (tenant_id, source_id, inserted_at, id)
WHERE source_id IS NOT NULL;
```

Leading with `(tenant_id, source_id)` lets the planner seek straight to the source's
rows and walk them in `(inserted_at, id)` order — strictly index-ordered, no Sort. Built
`CREATE INDEX CONCURRENTLY` + `@disable_ddl_transaction` (online build), `WHERE source_id
IS NOT NULL` (only source-attributed rows pay for it). It is registered in
`Loopctl.IndexHealth` (boot probe + recovery identical to the 27.9a index).

**Plan profile by index-enumeration shape (verified at 80k,
`by_source_change_feed_plan_scale_test.exs`):**

| Index query shape | Plan at prod scale | Cost profile |
| ----------------- | ------------------ | ------------ |
| `source_id=` (scalar) | Index Scan on `articles_tenant_source_inserted_id_idx`, walked in order, **no Sort** | true keyset, bounded by source selectivity (`refute_full_scan` + `assert_scan_rows_below`) |
| `tags=` (array `&&`) | tags GIN drives the scan, bounded by tag selectivity | same bounded GIN path 27.9a proved — NOT a full Seq Scan (`refute_seq_scan` + `assert_index_used` on the tags GIN) |

**by-tag stays the bounded GIN+btree path 27.9a already solved.** Because
`index_keyset_query` is a DISTINCT query from 27.9a's `keyset_query` (it forces
`status = :published` + the project OR-clause), the by-tag plan is pinned separately
**on `index_keyset_query`** in the same scale test (the literal #175 incident path).

### change feed (`GET /changes`) over the partitioned `audit_log`

The change feed is now a `(inserted_at, id)` **keyset**, ordered `inserted_at ASC, id
ASC`. The old `next_since` (timestamp-only) token is NOT tie-safe: audit `inserted_at`
is `utc_datetime_usec` and a bulk `Ecto.Multi` commits multiple rows at the SAME
microsecond, so a `since`-only follow-up (`inserted_at > next_since`) **skips** the tied
tail (silent gap) — exactly the drift the `id` tie-break fixes. The cursor
(`Loopctl.Audit.ChangesCursor`, `"changes_cursor"` namespace) steps PAST a specific row
regardless of ties. `next_since` is retained in the response for back-compat only; **new
callers MUST follow `next_cursor`.** `since` is still accepted for the first page; the
cursor takes precedence when both are present.

**No new index for the change feed.** `audit_log` is **RANGE-partitioned by
`inserted_at`** with an existing `(tenant_id, inserted_at)` btree; the keyset seek with
`tenant_id =` walks that index in order, with the `id` as the bounded tie-break recheck
inside an equal-timestamp run. `CREATE INDEX CONCURRENTLY` is **not supported on a
partitioned parent**, so a `(tenant_id, inserted_at, id)` parent index is intentionally
NOT added — the existing index already keeps the deep page index-backed. The scale test
asserts `refute_full_scan_audit` (no Seq Scan **and** no Bitmap Heap Scan → an ordered
Index Scan) on the request-path `Audit.changes_keyset_query/3` at 80k. The change-feed
read is routed through `Loopctl.HeavyRead` so it inherits the dedicated-pool
`statement_timeout` backstop (US-27.4), same as the index keyset path.

### Tenant safety on every surface

The cursor is decoded/verified with the **caller's** tenant key (from the auth
principal, never the cursor) under its surface namespace, so a forged/tampered/
cross-tenant/cross-surface cursor is rejected with **400** — proven by the forged-cursor
tests on each surface (`knowledge_index_keyset_controller_test.exs`,
`change_keyset_controller_test.exs`) and the namespace-separation test
(`keyset_cursor_test.exs`).

## Bulk write path — set-based archive/delete (US-27.12)

`Loopctl.Knowledge.BulkOps` mutates a whole selected set (by ids/tag/source) in
ONE `update_all`/`delete_all` + ONE audit event, inside a single `AdminRepo`
transaction. The hard-delete is FK-correct (article_links removed first, both
directions; access events cascade). Knobs (all config-driven):

| Setting | Default | Purpose |
| ------- | ------- | ------- |
| selector cap | 5000 | max rows a selector may match (else `:too_many`) |
| `:bulk_op_statement_timeout_ms` | 10s | per-statement `SET LOCAL statement_timeout` (blast-radius bound) |
| `:bulk_op_transaction_timeout_ms` | 15s | transaction-level checkout bound (reclaims the connection if statements chain) |
| `:bulk_delete_frozen_max` | 1000 | max id-set stored in a single-use dry-run token; larger selectors use the `confirm_hash` re-confirm-on-drift path |
| `:bulk_delete_token_ttl_seconds` | 300 | dry-run token lifetime (swept hourly by `BulkDeleteTokenCleanupWorker`) |

**Worst-case connection hold (AC-27.12.5):** a single bulk op runs on the small
**3-connection `AdminRepo`** pool and holds one connection for up to the
transaction timeout (~15s worst case). **Caveat:** a few concurrent bulk deletes
can transiently saturate the shared admin pool (other BYPASSRLS admin callers see
queue latency until they drain) — bounded, not corrupting, and gated to
`role: :user`. For a very large cleanup, run it off-peak or in narrower selectors;
do NOT raise the selector cap without re-checking the US-27.11 pool budget. The
statement timeout is intentionally short so a pathological plan fails fast and
frees the connection rather than holding it.

## `hnsw.ef_search` recall lever (US-27.11 → US-27.6b)

`hnsw.ef_search` is a pgvector **custom** GUC that does not exist until the
extension loads per-session, so it is **NOT** settable via Postgrex `:parameters`
on managed PG (fly mpg/RDS reject it: *"unrecognized configuration parameter"*).
It currently stays at the pgvector **default (40)**; recall is handled by
over-fetch + the US-27.6b under-fill signal.

If recall must be raised, set it on the **role** (applies per-session after the
extension loads), NOT via `:parameters`:

```sql
ALTER ROLE <heavy_read_role> SET hnsw.ef_search = 100;
```

Then confirm through the pool:

```sh
fly ssh console -a loopctl -C "/app/bin/loopctl rpc 'IO.inspect(Loopctl.HeavyReadRepo.query!(\"SHOW hnsw.ef_search\").rows)'"
```
