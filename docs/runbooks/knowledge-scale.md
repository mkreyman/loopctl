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

**US-33.6 (re-derived, no rebalance shipped — an explicit scope decision):** a
Repo 10 -> 7 / AdminRepo 3 -> 6 shift was investigated on the premise that the auth
hot path runs ~5 AdminRepo queries/request while Repo sits idle. That premise no
longer holds, but NOT down to zero: US-33.3's ETS read-through api-key cache +
US-33.4's debounced touch-writes drop the per-request AdminRepo cost from ~5
statements to ~1 cheap indexed STH SELECT — the `ValidateWitnessHeader` auth plug
still issues one uncached `AdminRepo` query per well-formed request
(`AuditChain.get_sth_at_position/2`), plus cold-cache miss load on a node during a
rolling deploy. **If you're reading this during a DB incident: AdminRepo is NOT
zero-load** — check `loopctl.admin_repo.checkout.queue_time` before ruling it out.
The Repo pool is shared with Oban's 38-wide queue concurrency, so it is not idle
either. The defaults above are UNCHANGED from US-27.11 pending real US-33.1
checkout-wait data — do not assume a rebalance landed just because the story is
closed; revisit with a real rebalance once that telemetry populates and points in a
specific direction.

### `HEAVY_READ_POOL_SIZE` (K) — sizing rationale (AC-27.11.1)

Default **8** supports **K ≈ 6** concurrent sub-2s heavy reads while
**reserving ~2 connections** for long-held **streamed-export** checkouts
(US-27.16), which hold a connection for *minutes* — a different profile than fast
reads. Raise it if export concurrency or heavy-read QPS grows, but only after
re-checking the connection budget below.

The fast-reads (K≈6) now serve **six** HeavyRead consumers: five fast heavy reads
(`suggested_links`, `semantic_search`, `distant_pairs`, `novelty`, `enumeration`) plus
one **rate-limited polling feed** — the US-27.9b change feed (`:change_feed`,
`GET /changes`). Note `suggested_links` is no longer strictly one-shot: since US-27.6b it
issues a **second bounded under-fill probe read** on the truncated (`returned < limit`)
path (an ANN-class `COUNT(*)` over the same inner top-`pool` subquery). That second read
is **strictly sequential** — it runs only after the main read's connection is released —
so the **peak concurrent checkout per request stays 1** and the K budget is unchanged (it
adds only throughput demand on the truncated path, itself capped by the api rate limiter;
see `Loopctl.DbCapacity`). The K budget is likewise unchanged by the change feed: that
read is a single CHEAP, fast-releasing bounded keyset page (connection released
immediately), and its poll QPS is bounded by the api pipeline's
`LoopctlWeb.Plugs.RateLimiter`, so even an orchestrator poll storm adds only brief
transient checkouts — it cannot saturate the fast slots or change the connection-count
budget below.

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

## Server-side `statement_timeout` (US-27.11 → US-27.4 → US-27.13)

Every heavy read gets a server-side `statement_timeout`, applied **per-read via
`SET LOCAL` inside a short transaction** by `Loopctl.HeavyRead` (`opts/1` → `all/one` →
`transaction/2`). Default **10s**, set with `HEAVY_READ_STATEMENT_TIMEOUT_MS`. A query that
exceeds it fast-fails (Postgres `57014`, surfaced as `db_statement_timeout` by US-27.3) and
the transaction commits/releases the connection promptly — so even a fully-saturated heavy
pool self-drains within `statement_timeout`.

> **⚠ Do NOT set this as a connection startup `:parameters` value (US-27.13 outage).** Fly
> MPG fronts Postgres with **pgbouncer**, which rejects a `statement_timeout` startup
> parameter with `FATAL 08P01 unsupported startup parameter` and **crash-loops the entire
> HeavyReadRepo pool** — every heavy endpoint then 503/504s. (It "works" against direct
> Postgres, which is why CI didn't catch it; `config_pgbouncer_safe_parameters_test.exs` +
> the `pgbouncer-e2e` CI job now guard this.) `SET LOCAL` inside a transaction is the only
> pgbouncer-safe way to set a server GUC; a GUC that must persist at connect goes via
> `ALTER ROLE` (e.g. a role-scoped `hnsw.ef_search` default — the live per-read recall
> override is `SystemConfig` via `SET LOCAL`, see the recall-lever section), never
> `:parameters`.

Verify the per-read timeout live (it is NOT a session/pool GUC, so a bare `SHOW` reads the
server default — read it INSIDE the SET LOCAL transaction):

```sh
fly ssh console -a loopctl -C "/app/bin/loopctl rpc '
  {:ok, v} = Loopctl.HeavyReadRepo.transaction(fn ->
    Loopctl.HeavyReadRepo.query!(\"SET LOCAL statement_timeout = 10000\")
    Loopctl.HeavyReadRepo.query!(\"SHOW statement_timeout\").rows
  end); IO.inspect(v)'"
```

> **Note for US-27.16 (streamed export):** a minutes-long export must NOT inherit
> the fast read timeout. Use `Loopctl.HeavyRead.transaction(fun, statement_timeout:
> ms)`, which issues `SET LOCAL statement_timeout = ms` scoped to that transaction
> (the stream must be enumerated INSIDE the transaction). A POSITIVE explicit bound
> is required — `0`/unlimited is rejected, so a runaway export can't pin a connection
> on the small heavy pool forever.

## Per-endpoint `statement_timeout` + slow-query logging (US-27.4)

**Default heavy-read timeout:** every heavy read runs under the per-read `SET LOCAL`
`statement_timeout` (`HEAVY_READ_STATEMENT_TIMEOUT_MS`, default 10s — see above). When
it fires, the request fast-fails as the structured **504 `db_statement_timeout`**
(US-27.3) and the connection is released promptly — no 30s hang.

**Per-endpoint override (optional):** to give one endpoint a tighter (or looser) bound,
set `:heavy_read_statement_timeout_overrides` (ms) in config — keys
`:suggested_links`, `:semantic_search`, `:distant_pairs`, `:distant_pairs_bridge`, `:novelty`, `:vector_search`:

```elixir
config :loopctl, :heavy_read_statement_timeout_overrides, %{suggested_links: 5_000}
```

An override (or the default) applies via `SET LOCAL` inside a short transaction on the
dedicated heavy pool (justified by the 8-conn sizing). Leave the map empty unless an
endpoint needs a bound different from the `HEAVY_READ_STATEMENT_TIMEOUT_MS` default.

**Heavy-read endpoints** (those using `HeavyRead.all/one`): `:suggested_links`,
`:semantic_search`, `:distant_pairs`, `:distant_pairs_bridge`, `:novelty`, `:enumeration`. The enumeration endpoint
(`:knowledge_search_controller` list mode, `list_filtered/2`) now routes through HeavyRead to
inherit the per-read SET LOCAL statement_timeout and optional per-endpoint override (matching
the other endpoints). Enumeration pages up to `limit: 1000` rows per request.

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

## pgbouncer compatibility (US-27.13 — the heavy-read outage)

Fly Managed Postgres fronts Postgres with **pgbouncer**. The US-27.13 outage was a
`statement_timeout` connection STARTUP parameter on `HeavyReadRepo` that pgbouncer rejected
(`FATAL 08P01 unsupported startup parameter`), crash-looping the pool so every heavy endpoint
503/504'd. It was invisible to CI because CI uses **direct Postgres** (which accepts the
param). Hard-won rules for anything touching the DB layer behind pgbouncer:

- **No GUC via connection `:parameters`.** A server GUC is applied per-read via `SET LOCAL`
  inside a transaction (`Loopctl.HeavyRead`); a GUC that must persist at connect goes via
  `ALTER ROLE` (e.g. a role-scoped `hnsw.ef_search` default; the live per-read recall
  override is `SystemConfig` via `SET LOCAL` — see the recall-lever section). The config-lint
  (`config_pgbouncer_safe_parameters_test.exs`) blocks a re-added startup `:parameters` GUC —
  but that is ONLY the startup-parameter member of the class. It does NOT guard the other
  pgbouncer-sensitive paths below; those depend on the **pool mode**.
- **`prepare: :unnamed` on all three repos.** Under pgbouncer **transaction** pooling, named
  prepared statements cached on one server connection break when the next transaction lands on
  another (`26000`/`42P05`). All repos set `prepare: :unnamed`; the `pgbouncer-e2e` job proves
  a query reused across `pool_size: 2` transactions succeeds.
- **Pool-mode-sensitive paths NOT covered by the config-lint:** Oban's Postgres notifier
  (LISTEN/NOTIFY) and any `Repo.stream` without an enclosing transaction silently misbehave
  under transaction pooling. Keep them in mind for any new feature.
- **VERIFY the live pgbouncer config** (the single most important setting for this whole
  design, currently NOT pinned in-repo): run `SHOW CONFIG` via the pgbouncer admin console (or
  Fly support) and record `pool_mode` and `ignore_startup_parameters` here with a "last
  verified" date — same discipline as `max_connections`. Fly MPG documents **session mode** as
  the default; the CI `pgbouncer-e2e` deliberately runs the STRICTER **transaction** mode (the
  08P01 rejection is pool-mode-independent, and transaction mode is the harder case for
  prepared statements), so a green e2e is a conservative superset, not an exact prod mirror.

### Per-read transaction hold-time (re-verify under load — M1)

US-27.13 changed each heavy read from a single autocommit `SELECT` to a short
`BEGIN; SET LOCAL statement_timeout; SELECT; COMMIT` (~3 server round-trips, connection held
BEGIN→COMMIT). `Loopctl.DbCapacity` models connection **count**, not hold-time, so the K≈6
fast-read budget is now slightly more contended per the same concurrency. The per-read
`statement_timeout` makes the pool **self-drain** (a runaway read is canceled), so this is a
latency/throughput risk, not a deadlock — but per the "verify against prod scale" practice,
re-check heavy-read p95 + pool queue-wait under load after deploy (the #172 incident proves
this pool is the real contention point). Measured prod baselines at ~77k (deployed fix):
`suggested_links` ~59ms, semantic ~45ms, novelty ~1.4s. `distant_pairs` was the slowest at
~7.9s until #202/#203: its cost was an exact `total_count` `count(*)` query — a full
O(candidates²) pass over the sampled self-join that could NOT early-terminate. That count is
now removed (the endpoint returns `count`/`has_more`, no exact total), leaving only the
ordered `LIMIT limit+1` page, which early-terminates in a few ms (local 1.5k-corpus profile:
count pass ~2.3s vs page ~6–18ms). Confirm the new prod p95 (<2s Theme 2 target) via
`fly ssh`/EXPLAIN ANALYZE after deploy per the "verify against prod scale" practice.

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

**No new index for the change feed.** `audit_log` is **RANGE-partitioned by month** with
an existing `(tenant_id, inserted_at)` btree. The keyset seek (`tenant_id =` + the
`(inserted_at, id)` row-value comparison, `ORDER BY inserted_at, id`) plans as
**per-partition Index Scans** (one scan per month the cursor range touches) combined
under an ordered node. Because the index lacks `id`, the planner finishes the global
`(inserted_at, id)` order one of two cost-equivalent ways: **Append + a top-level
Incremental Sort** (the empirical choice at 80k — each partition is presorted on
`inserted_at`, the incremental sort resolves the `id` tie-break within each
equal-timestamp run) or a **Merge Append**. Either way: no Seq Scan, no Bitmap over the
corpus — bounded by the keyset seek (~O(page)). `CREATE INDEX CONCURRENTLY` is **not
supported on a partitioned parent**, so a `(tenant_id, inserted_at, id)` parent index is
intentionally NOT added — the existing index already keeps the deep page index-backed
(the `id` tie-break is a cheap incremental sort, not a corpus scan). The scale test seeds
across **≥2 monthly partitions** (so the deep page produces a real multi-partition
ordered scan, matching prod — not a single-partition shortcut) and asserts BOTH
`assert_ordered_multi_partition_scan` (≥2 partitions via Index Scan under Merge
Append/Append+Incremental-Sort) AND `refute_full_scan_audit` (no Seq Scan **and** no
Bitmap Heap Scan) on the request-path `Audit.changes_keyset_query/3`. The change-feed read
is routed through `Loopctl.HeavyRead` so it inherits the dedicated-pool `statement_timeout`
backstop (US-27.4), same as the index keyset path; it is the **sixth** HeavyRead consumer
(the rate-limited polling feed — see the HEAVY_READ_POOL_SIZE sizing note above).

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
on managed PG (fly mpg/RDS reject it: *"unrecognized configuration parameter"* —
still guarded by `config_pgbouncer_safe_parameters_test.exs`).

**Primary lever (US-38.4): the live-tunable SystemConfig `hnsw_ef_search` key.**
It is applied per-ANN-read via `SET LOCAL hnsw.ef_search = <value>` inside the
SAME short heavy-read transaction that already scopes `SET LOCAL statement_timeout`
(`Loopctl.HeavyRead.run_timed_transaction/4`) — so there is **no** new
pool-starvation risk (the pre-US-27.13 "SET LOCAL needs a transaction → #172
starvation" objection is stale; the transaction is already there). It defaults to
the pgvector default **40**; recall is handled by over-fetch + the US-27.6b
under-fill signal + this knob. To raise recall fleet-wide with **no redeploy**:

```sql
UPDATE system_configs SET value = 100, updated_at = now() WHERE key = 'hnsw_ef_search';
```

The change is live on this node on write and on every other node within a minute
(the `SystemConfigRefreshWorker` cron). The value is clamped to pgvector's accepted
`[1, 1000]` by `Loopctl.HeavyRead.hnsw_ef_search/0`, so a bad value can never make
the `SET LOCAL` raise. Only the pgvector-ANN endpoints
(`Loopctl.HeavyRead.ann_endpoints/0` — `suggested_links`, `semantic_search`, `novelty`,
`vector_search`, `memory_recall`; the `distant_pairs*` self-joins are NOT ANN and never
carry it) get it, and only when the value **differs from the pgvector default 40** — at
the default no per-read `SET LOCAL` is issued at all (see the precedence note below).

**Alternative lever: role-level `ALTER ROLE`** (a role-scoped default that applies
per-session after the extension loads) — still works, and is HONORED because the
`SystemConfig` per-read `SET LOCAL` is emitted **only for a non-default value**. This is a
real precedence contract, not two competing levers:

- `SystemConfig = 40` (default) → **no** per-read `SET LOCAL` → the session/role default
  governs, so `ALTER ROLE ... SET hnsw.ef_search = N` is honored fleet-wide.
- `SystemConfig = <non-default>` → a per-read `SET LOCAL hnsw.ef_search = <value>` is issued
  and, because `SET LOCAL` overrides any role/session default for its transaction, that
  value wins for the ANN read.

So use `ALTER ROLE` for a role-scoped default that must persist independent of the app
config table (leaving `SystemConfig` at 40); use `SystemConfig` for a live, no-redeploy
fleet-wide override. NB: to pin ANN reads to exactly 40 while a higher `ALTER ROLE` default
exists, lower the role default — setting `SystemConfig = 40` is treated as "no override" and
will NOT force the reads back down (that is the whole point of not shadowing the role lever).

```sql
ALTER ROLE <heavy_read_role> SET hnsw.ef_search = 100;
```

Then confirm the value through the pool. A role default shows on a plain `SHOW`; a
`SystemConfig` per-read value is `SET LOCAL`, so confirm it inside a transaction:

```sh
# Role default (ALTER ROLE) — plain SHOW on a fresh checkout:
fly ssh console -a loopctl -C "/app/bin/loopctl rpc 'IO.inspect(Loopctl.HeavyReadRepo.query!(\"SHOW hnsw.ef_search\").rows)'"
# SystemConfig per-read value — inside a transaction (as the ANN read runs it):
fly ssh console -a loopctl -C "/app/bin/loopctl rpc 'Loopctl.HeavyReadRepo.transaction(fn r -> r.query!(\"SET LOCAL hnsw.ef_search = #{Loopctl.HeavyRead.hnsw_ef_search()}\"); IO.inspect(r.query!(\"SHOW hnsw.ef_search\").rows) end)'"
```

### `hnsw.iterative_scan` filtered-recall lever (#488 / #491)

The sibling lever to `hnsw_ef_search`, for a DIFFERENT failure: a **filtered** ANN
(tenant scope, dimension, category, status) applies its residual filters AFTER the index
walk, so on a SHARED HNSW index a tenant can fill its whole `ef_search` candidate window
with OTHER tenants' rows and return **zero** of its own — an under-return that looks like
a recall bug. pgvector >= 0.8's `hnsw.iterative_scan` fixes it by continuing the walk until
the `LIMIT` is filled (or `hnsw.max_scan_tuples` is hit).

It ships **OFF** and is a live `SystemConfig` INT CODE (`Loopctl.HeavyRead.hnsw_iterative_scan/0`):

| `hnsw_iterative_scan` | mode emitted |
|---|---|
| `0` (default / missing / unknown code) | `off` — no `SET LOCAL` at all |
| `1` | `relaxed_order` |
| `2` | `strict_order` |

```sql
-- confirm pgvector >= 0.8 FIRST: SELECT extversion FROM pg_extension WHERE extname = 'vector';
UPDATE system_configs SET value = 1, updated_at = now() WHERE key = 'hnsw_iterative_scan';
-- optional ceiling on how far the iterative walk may go (pgvector default 20000):
UPDATE system_configs SET value = 50000, updated_at = now() WHERE key = 'hnsw_max_scan_tuples';
```

Contract, and the ways it can silently do nothing:

- **`SystemConfig` is the ONLY source.** Unlike `ef_search` there is no `ALTER ROLE`
  interaction to reason about and, deliberately, **no `Application` config override** — an
  environment pin would either shadow the operator lever or (in the test env) stop CI
  exercising the shipped default. `config_embedding_read_path_test.exs` fails the build if
  a `:hnsw_iterative_scan` key appears in any `config/*.exs` file, in either the
  `config :loopctl, :key, value` or the `config :loopctl, key: value` shape.
- **Fail-closed capability probe.** On pgvector < 0.8 the GUC does not exist. Enabling the
  key there is a **silent NO-OP**, not an outage: `Loopctl.HeavyRead.iterative_scan_supported?/0`
  probes `pg_extension` on the heavy-read repo (cached in `:persistent_term` with a TTL) and
  logs a warning naming the detected version — or, when the extension is not installed at
  all, a distinct "pgvector is NOT INSTALLED" warning, so you are not sent chasing an
  upgrade that is not the problem. A probe that could not reach a conclusion (pool timeout,
  DB blip, wedged-pool exit) is negative-cached for 60s only, so one bad moment cannot pin
  the lever off until a redeploy — while a sustained outage costs one probe per minute
  instead of one per ANN read. The conclusive verdict expires after 10 min so a backend
  change (replica failover onto an older pgvector) self-heals.
- **Only ANN endpoints, only when enabled.** `SET LOCAL hnsw.iterative_scan = <mode>` plus
  `SET LOCAL hnsw.max_scan_tuples = <n>` are emitted inside the same short heavy-read
  transaction as `statement_timeout`/`ef_search`, for `Loopctl.HeavyRead.ann_endpoints/0`
  only. At `0` no GUC round-trip happens and the probe is never paid for.
- **Verify through the pool** the same way as `ef_search` (inside a transaction — it is a
  `SET LOCAL`), and expect latency to rise on filtered queries: the walk is longer by
  construction. `hnsw_max_scan_tuples` is the bound; it is clamped to `[1, 1_000_000]`.

### Recall ceiling + the under-fill signal (US-27.6b)

Recall on every kNN/`suggested_links` read is bounded by **two** things: `hnsw.ef_search`
(default ~40 — the breadth above) AND the over-fetch `pool` (`pool_size/2`:
`k * :vector_pool_factor |> max(:vector_pool_floor) |> min(:max_vector_pool) |> max(k)`,
defaults 5 / 100 / 500). For a **densely-linked hub**, the nearest pool can be almost
entirely already-linked, so `suggested_links` legitimately returns **fewer than the
requested limit** even though near (above-threshold) unlinked neighbors would exist if
not already linked. **This is expected, not a bug** — it is the price of the
index-correct path. The hazard is that it looks identical to "no neighbors exist", so it
is made **observable**:

- **Operator signal:** `Loopctl.Knowledge.suggest_links_with_meta/3` emits a
  `[:loopctl, :knowledge, :vector_search, :under_fill]` telemetry event (id-only payload:
  `tenant_id`, `endpoint`, `requested`, `returned`, `pool`, `ann_candidates`,
  `above_threshold`, `excluded_by_link` — NO vector literals/bodies) **once per request**,
  ONLY when above-threshold neighbors the ANN surfaced were hidden by the already-linked
  anti-join (`above_threshold > returned`). It does NOT fire for a **sparse region** whose
  whole ANN pool is below the similarity threshold (`above_threshold == returned`) — that
  is correct emptiness, not recall loss. The detector is **ef_search-independent**: under
  HNSW the ANN delivers only `~ef_search` (~40) candidates, so the old `ann_candidates >=
  pool` "pool full" gate was degenerate (never true at scale, silently suppressed the
  signal) and was removed. `excluded_by_link = above_threshold - returned` is the
  un-conflated count of above-threshold neighbors the anti-join removed; `ann_candidates`
  is the ef_search-bounded recall-breadth diagnostic. Aggregated by US-27.15.
- **Consumer signal:** the `suggested_links` response `meta` carries
  `recall_truncated`/`pool_exhausted` (same flag) so an agent distinguishes an INCOMPLETE
  result from an empty one.

Detecting under-fill costs **one bounded extra read** — a single aggregate
(`COUNT(*)` for `ann_candidates` plus a `COUNT(*) FILTER (similarity > threshold)` for
`above_threshold`) over the **same inner ANN top-`pool` subquery** the main query draws
from (`LIMIT pool`, so it touches at most `:max_vector_pool` rows, ≤500) — issued ONLY on
the `returned < limit` path (zero added cost on the common full-result path), on the same
dedicated heavy-read pool. It is an ANN-class read (same plan shape as the main query). A
connectivity/timeout fault on this advisory probe is fail-soft: the suggestions are still
returned with no truncation signal rather than failing the request.

**Raising recall** (US-38.4) is the live `SystemConfig hnsw_ef_search` knob (or the
`ALTER ROLE … SET hnsw.ef_search` role default, honored while `SystemConfig` sits at 40 —
see the precedence contract above) documented above. A non-default `SystemConfig` value is
applied per-ANN-read via `SET LOCAL hnsw.ef_search` inside the heavy read's EXISTING short
transaction, so it no longer re-introduces the #172 small-pool starvation (that objection
predated US-27.13's per-read transaction). It is still never a startup `:parameters` value
(pgbouncer rejects that). Until an operator raises it, recall stays at the default 40, NO
per-read `SET LOCAL` is issued, and recall is handled by over-fetch + this under-fill signal.

## Metrics & alerting (US-27.15)

US-27.3/27.4/27.6b emit structured **logs/events**, but "recurring slow queries are
visible before they become incidents" is hard to satisfy by grepping a 7-day log. US-27.15
aggregates those signals into **three `Telemetry.Metrics`** exported on an **internal
`:9568/metrics`** endpoint that Fly's **managed Prometheus** scrapes over the private 6PN
network (`fly.toml [metrics]`). The series appear in **`fly-metrics.net` Grafana** for
**visualization**.

> **Alerting reality (corrected):** `fly-metrics.net`'s managed Grafana has **alerting
> DISABLED** — per Fly's docs, *"Fly.io doesn't include built-in alerting on metrics, so
> you'll need to set up alerting yourself against the Prometheus endpoint."* So the PromQL
> expressions below VISUALIZE a trend but **nothing fires** from them on fly-metrics.net.
> The **firing** path (AC-27.15.2) that ships is a **loopctl-owned threshold checker**,
> [`Loopctl.Telemetry.ScaleAlerts`](#the-firing-alert-path-loopctltelemetryscalealerts),
> which POSTs a webhook on breach — self-contained, no external Grafana/Alertmanager.

> **Scope (AC-27.15.4 — USER-signed-off):** metric emission + the Prometheus reporter +
> the **ScaleAlerts firing webhook** ship in this story. The PromQL expressions below are
> **query bodies** for an **OPTIONAL self-hosted** Grafana/Alertmanager (they require your
> own Grafana — fly-metrics.net cannot install or run them). The bespoke Grafana
> **dashboard JSON** (issue #196) now ships as
> [`docs/observability/scale-metrics-dashboard.json`](../observability/scale-metrics-dashboard.md)
> (import into fly-metrics.net Grafana — **visualization only**); an external
> **Alertmanager** wiring remains an optional self-hosted follow-up. loopctl has no Sentry;
> the ScaleAlerts webhook is the durable firing signal. To inspect `/metrics` locally, set
> `config :loopctl, :metrics_reporter_enabled, true` in `config/dev.exs`.

### Surface & security

- **Reporter:** `TelemetryMetricsPrometheus`, started **through the fault-isolating
  `Loopctl.Telemetry.MetricsReporter` wrapper** (a supervised child of `LoopctlWeb.Telemetry`),
  only when `:metrics_reporter_enabled` is true (prod via `runtime.exs`; **off in test** so
  the suite never binds the port; flip on in dev to read `localhost:9568/metrics`). The
  wrapper's `init` always succeeds and it starts/retries the reporter out of band, so a bind
  failure (`:eaddrinuse`), a **raise**, or an **exit** from the reporter start can never
  crash the telemetry supervisor and cascade into the API — worst case is "no `/metrics`
  until the port frees". A reporter adopted via `{:already_started, pid}` is **monitored**,
  so its later death is detected and retried too.
- **Bundled stack decision (architect F7):** the reporter is the bundled
  `telemetry_metrics_prometheus` (which runs its OWN cowboy/ranch listener — a second HTTP
  stack alongside the app's Bandit). This was chosen **deliberately** over
  `telemetry_metrics_prometheus_core` + a hand-rolled Bandit scrape endpoint: the maintained
  standard scrape server, isolated on the internal port and behind the fault-isolating
  wrapper, beats bespoke scrape code we'd have to maintain. The extra cowboy/ranch footprint
  (on an internal-only port) is **accepted**.
- **Internal-only:** `/metrics` binds the SEPARATE internal port **9568** — it is NOT in
  `fly.toml`'s `http_service` (only public **8080** is). Fly's scraper reaches 9568 over
  6PN; the internet cannot. Port is tunable via `METRICS_PORT` but MUST match the
  `[metrics]` block.
- **No-leak (AC-27.15.3):** labels are safe dimensions ONLY — `endpoint` (a matched
  `Controller.action` / heavy-read endpoint atom, never a raw path with ids), `mapped_code`
  (a bounded DB-error class), and a **cap-gated** `tenant_id`. There is **no `article_id`
  label**, and no raw vector / body / param ever reaches a tag.

### The three metrics

| Metric (Telemetry.Metrics name) | Type | Labels | Source event | Meaning |
| --- | --- | --- | --- | --- |
| `loopctl.db.error.count` | counter | `endpoint`, `mapped_code`, *(cap-gated)* `tenant_id` | `[:loopctl, :db, :error]` (`DBErrorLogger`) | Mapped DB errors by endpoint + class. `mapped_code="db_statement_timeout"` is the 57014 timeout counter; siblings are serialization / deadlock / catch-all. |
| `loopctl.heavy_read_repo.query.duration` | distribution (histogram) | `endpoint` **only** | `[:loopctl, :heavy_read_repo, :query]` | Heavy vector/enumeration read latency by endpoint. **No `tenant_id`** — endpoint × tenant × buckets is the multi-tenant cardinality bomb. |
| `loopctl.knowledge.vector_search.under_fill.count` | counter | `endpoint`, *(cap-gated)* `tenant_id` | `[:loopctl, :knowledge, :vector_search, :under_fill]` (US-27.6b) | Recall under-fill events by endpoint (a densely-linked hub hiding above-threshold neighbors). |

> **Histogram excludes timeouts (architect F6):** the heavy-read latency **histogram**
> measures **SUCCESSFUL** heavy-read latency — a query that statement-times-out raises and
> never records a `total_time` sample, so it is **absent** from the histogram (and from the
> p95). Timed-out queries are captured instead by the **`db_statement_timeout` COUNTER**
> (and drive the ScaleAlerts timeout-rate alert). The two together cover the SLO: p95 for
> "slow but completing", the timeout counter for "gave up". Don't be surprised the p95 looks
> healthy while timeouts climb — that's the counter's job, not the histogram's.

> **`endpoint=:unknown` triage (security AREA-10):** an `:unknown` `endpoint` label on the
> `db_error` counter means the DB error surfaced **before dispatch** / on a **non-routed**
> request (no `phoenix_controller`/`phoenix_action` in `conn.private`) — e.g. an error in a
> plug ahead of the router, or a request to an unmatched path. When triaging a
> `loopctl_db_error_count{endpoint="unknown"}` spike, look at pre-router plugs / health
> probes / scanners, not a specific controller action.

### Prometheus metric names (dot→underscore + histogram suffixes)

`Telemetry.Metrics` → Prometheus munges `.` to `_`; a `distribution` becomes a histogram
with `_bucket` / `_sum` / `_count` series. So the scraped names are:

- `loopctl_db_error_count` (labels: `endpoint`, `mapped_code`, `tenant_id`)
- `loopctl_heavy_read_repo_query_duration_bucket` / `_sum` / `_count` (label: `endpoint`,
  plus `le` on the `_bucket` series)
- `loopctl_knowledge_vector_search_under_fill_count` (labels: `endpoint`, `tenant_id`)

Histogram buckets (ms): `10, 50, 100, 250, 500, 1000, 2500, 5000, 10000`.

### Tenant-label cardinality gate (AC-27.15.3)

`tenant_id` is a **counter** label ONLY while total tenants ≤ `:metrics_tenant_label_cap`
(default **1000**, env `METRICS_TENANT_LABEL_CAP`). Above the cap the label collapses to the
fixed sentinel **`_aggregated`** (cardinality 1), and per-tenant attribution falls back to
logs (which still carry `tenant_id`). It is **NEVER** a histogram label. The gate is a
boolean cached in `:persistent_term`, recomputed by a `telemetry_poller` measurement
(`Loopctl.Telemetry.ScaleMetrics.refresh_tenant_label_gate/0`, every 10s) — so there is **no
per-emit DB hit**, and an un-warmed boot defaults to OFF (aggregate) so it can never emit an
unbounded label. **Operational note:** raising the cap toward a very large fleet re-admits
per-tenant series on the two counters — re-check Prometheus series budget before raising it.

### The firing alert path: `Loopctl.Telemetry.ScaleAlerts`

Because fly-metrics.net Grafana **cannot alert** (above), the firing path (AC-27.15.2) is a
supervised, loopctl-owned threshold checker. It windows the SAME three scale signals via
**atomic ETS counters** (the request-path telemetry handlers write with
`:ets.update_counter` — NO per-event GenServer call, so it is not a hot-path bottleneck),
evaluates them on a timer, and **POSTs a webhook on breach**. No external Grafana or
Alertmanager is required.

**How it works:**

- Three tumbling-window counters: `db_statement_timeout` count, under-fill count, and a
  **bucketed** heavy-read latency histogram (the same buckets as the Prometheus histogram,
  so its p95 is the same bucket-based approximation — bounded memory, no per-sample
  reservoir). Each handler is self-rescuing: a handler fault can never break the request it
  observes.
- Every `:scale_alert_check_interval_ms` the window is read **and reset** (tumbling), and
  per-window values are compared to thresholds:
  - `timeout_rate` = timeouts / window-minutes (per-minute),
  - `under_fill_rate` = under-fill events / window-minutes,
  - `p95_latency_ms` = the bucket upper bound crossing 95% of samples (skipped below a small
    sample floor to avoid noise).
- **Edge-triggered debounce:** an alert fires on the **transition into** breach, NOT on
  every interval while sustained; the metric **re-arms** (can fire again) once it clears back
  below threshold. This is the anti-spam guarantee.
- On breach it POSTs an **id-only JSON payload** to `:scale_alert_webhook_url` via the SAME
  `:webhook_delivery` DI the webhook worker uses (operator/system-scoped — it does NOT use
  the tenant-scoped `EventGenerator`). If the URL is `nil`, alerting is **OFF (opt-in)**: the
  breach is logged at `:warning` and nothing is POSTed. A delivery error is logged, not
  raised.

**Payload shape** (no tenant content / vectors / params / SQL ever appears):

```json
{
  "alert": "scale_degradation",
  "metric": "db_statement_timeout_rate",   // | "heavy_read_p95_latency_ms" | "under_fill_rate"
  "value": 6.0,
  "threshold": 5,
  "window_seconds": 60,
  "at": "2026-06-25T12:00:00.000000Z"
}
```

**Config knobs** (config.exs defaults; prod via env in runtime.exs):

| Key | Env var | Default | Meaning |
| --- | --- | --- | --- |
| `:scale_alerts_enabled` | — | `false` (prod `true`) | Start the supervised checker. OFF in `:test` so the suite never runs its timers / owns its ETS table. |
| `:scale_alert_webhook_url` | `SCALE_ALERT_WEBHOOK_URL` | `nil` | Operator webhook (Slack/PagerDuty/generic). `nil` = alerting off (log-only). |
| `:scale_alert_check_interval_ms` | `SCALE_ALERT_CHECK_INTERVAL_MS` | `60000` | Window evaluate-and-reset cadence. |
| `:scale_alert_window_ms` | — | = check interval | Window length for rate math / `window_seconds`. |
| `:scale_alert_timeout_rate_per_min` | `SCALE_ALERT_TIMEOUT_RATE_PER_MIN` | `5` | Timeout-rate threshold (timeouts/min). |
| `:scale_alert_p95_latency_ms` | `SCALE_ALERT_P95_LATENCY_MS` | `2000` | p95 heavy-read latency threshold (ms). |
| `:scale_alert_under_fill_rate_per_min` | `SCALE_ALERT_UNDER_FILL_RATE_PER_MIN` | `30` | Under-fill rate threshold (events/min). |

To enable alerting in prod: set `SCALE_ALERT_WEBHOOK_URL` to a Slack/PagerDuty/generic
incoming webhook. Tune the three thresholds per environment via their env vars.

### Optional self-hosted alert rules (PromQL — requires YOUR OWN Grafana/Alertmanager)

These are **query bodies**, NOT a firing path on fly-metrics.net (its Grafana cannot install
or run alert rules). They are provided for an **optional self-hosted** Grafana/Prometheus +
Alertmanager that scrapes the same `/metrics`. Configure as alert rules over a 5-minute
window; thresholds are defaults — tune per environment (the `> THRESHOLD` literal).

**1. db_statement_timeout rate (per endpoint)** — default `THRESHOLD = 0.1` (≈ 6 timeouts/min
on one endpoint):

```promql
sum(rate(loopctl_db_error_count{mapped_code="db_statement_timeout"}[5m])) by (endpoint) > 0.1
```

**2. p95 heavy-read latency (per endpoint)** — default `THRESHOLD_MS = 2000` (the sub-2s
heavy-read SLO the pool is sized for, US-27.11):

```promql
histogram_quantile(
  0.95,
  sum(rate(loopctl_heavy_read_repo_query_duration_bucket[5m])) by (le, endpoint)
) > 2000
```

**3. recall under-fill rate (per endpoint)** — default `THRESHOLD = 0.5` (a sustained
under-fill trend, not a one-off dense hub):

```promql
sum(rate(loopctl_knowledge_vector_search_under_fill_count[5m])) by (endpoint) > 0.5
```

> The `_bucket` unit is **milliseconds** (the metric's `unit: {:native, :millisecond}`), so
> `histogram_quantile` returns ms directly — compare against a ms threshold.

### Per-tenant drill-down fallback (when the tenant label is dropped)

Above the tenant cap the metrics aggregate `tenant_id` to `_aggregated`, so a spike that
needs per-tenant attribution drills down via the **7-day logs** in `fly-metrics.net`
(LogsQL), which still carry `tenant_id` on the structured `db_error` / slow-query lines.
Example (timeouts for one tenant over the last hour):

```logsql
_time:1h "mapped_code=db_statement_timeout" "tenant_id=<TENANT_UUID>"
```

For slow-read latency by tenant, query the US-27.4 `slow_query` lines
(`"slow_query" "tenant_id=<TENANT_UUID>"`). Lower `:slow_query_threshold_ms` to widen what
the logs capture if needed (see the slow-query section above).

## Standing vector-endpoint CI gates (US-27.8)

US-27.8 turns "ALL vector endpoints index-backed + under budget at prod scale" into
**standing CI properties** so a future regression fails CI, not prod. There are two kinds
of gate, and they are independent:

### 1. The cosine-`<=>` reintroduction lint (runs in the `lint` CI job)

`mix credo --strict` runs a custom check,
`Loopctl.Credo.Check.CosineQueryReintroduction`, that FAILS the build if a NEW hand-rolled
cosine `<=>` (in a `fragment(...)` / raw SQL) appears in `lib/loopctl` **outside** the
sanctioned helper `Loopctl.Knowledge.VectorSearch` and **not** in the auditable allowlist
`Loopctl.Knowledge.CosineLintExceptions`.

- The check lives in `.credo/checks/cosine_query_reintroduction.ex` (OUTSIDE `lib/`, so
  `MIX_ENV=prod mix compile` never drags it into the release) and is loaded by Credo via
  `.credo.exs` `requires:`. `.credo.exs` is the full `mix credo.gen.config` default set
  PLUS this one check — no default check is dropped or weakened.
- **Adding a legitimately-different cosine shape?** Register `{module, function, arity}`
  (with a non-empty one-line rationale) in `Loopctl.Knowledge.CosineLintExceptions` — a
  visible, reviewable diff — instead of an inline comment the lint can't see.
- **CRITICAL:** the allowlist exempts only the LINT location. It does NOT exempt a bad
  query SHAPE from the scale plan-gate — an index-defeating change inside an allowlisted
  function STILL fails `refute_full_scan`/`refute_seq_scan` at 80k (proven by
  `cosine_lint_vs_scale_gate_scale_test.exs`).

### 2. The per-endpoint scale gates (run in the `Scale Nightly` matrix)

Every vector path carries an 80k index-usage gate on its REAL request-path query:
`suggested_links` + `search_semantic` (results + count) + the auto-link worker
(`topk_endpoints_scale_test.exs`), `distant_pairs` + `novelty`
(`distant_pairs_novelty_scale_test.exs`). Each `:scale_nightly` file is in the
`.github/workflows/ci.yml` `scale_file` matrix; `scale_verification_runbook_test.exs`
enforces set-equality so coverage can't silently erode.

**End-to-end wall-clock latency (`vector_endpoint_e2e_latency_scale_test.exs`).** The
PRIMARY signal is the deterministic plan assertion (index-backed, no full-corpus Sort).
SECONDARY/ADVISORY is a wall-clock budget measured through the REAL HTTP endpoint (a timed
`Phoenix.ConnTest` request: auth + RLS + query + serialize + render) for `suggested_links`
and `semantic` search:

- Budget config: **`:scale_latency_budget_ms`** (default **2000ms** — the Theme-2 "<2s"
  target). Deliberately generous so it does not flake on shared CI hardware; the plan gate
  is the real arbiter. **Tune it UP** as prod grows beyond the floor — a documented step,
  never a silent default (AC-27.8.6).

**Calibration is asserted, not assumed (`scale_calibration_mismatch_scale_test.exs`).**

- **Seed floor.** The vector gates call `PlanAssertions.assert_scale_floor!/1`, which
  RAISES a clear calibration error if the seeded tenant has fewer than
  `Loopctl.Knowledge.ScaleSeed.prod_article_floor/0` (currently **80_000**) committed
  articles — a sub-floor gate is theatre (the planner Seq-Scans happily at toy scale and an
  index-usage assertion false-greens). **Bumping the floor** as prod grows = update
  `@prod_article_floor` in `Loopctl.Knowledge.ScaleSeed` (a documented step).
- **`hnsw.ef_search` parity.** The under-fill gate asserts the EFFECTIVE `ef_search`
  (`SHOW hnsw.ef_search`) is identical on the gate connection and a prod-shaped one; the
  calibration test proves the FAILURE direction (a divergent value RAISES). When EITHER
  recall lever lands a non-default value — a role-scoped `ALTER ROLE … SET hnsw.ef_search = N`
  default, OR the live `SystemConfig hnsw_ef_search` per-read `SET LOCAL` (US-38.4) — update
  the `== "40"` pin in `vector_search_under_fill_scale_test.exs` to the new effective value.
