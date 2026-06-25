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
