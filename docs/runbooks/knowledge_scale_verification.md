# Runbook: Verifying a knowledge scale/perf fix (US-27.5)

> **Why this exists.** Three of the four `suggested_links` fixes (#170–#173) were
> closed as "resolved end-to-end" while still **broken in prod**, because the only
> gate was green CI. The bug was finally pinned by a session that ran `fly logs` and
> a live `EXPLAIN ANALYZE` against the real corpus (wiki `bd4a26b6`; memory
> `feedback-verify-against-prod-scale`). This runbook turns that heroic, ad-hoc
> debugging into a **standing, repeatable gate**: no scale/perf fix is "done" on
> "CI-green + merged" alone.
>
> Companion: [`knowledge-scale.md`](knowledge-scale.md) (the live pool/timeout/index
> facts). This document is the **process**; that one is the **current values**.

The standard for closing a scale/perf issue is:

> **verified against representative scale AND confirmed on the live deployed build** —
> not "CI passed."

---

## Retrieving the prod error

**loopctl runs NO Sentry / error-tracker.** Database exceptions, query timeouts,
and crashes are written to **stdout via `Logger`** and are reachable through Fly's
log stream. A future session must NOT conclude "we have no prod visibility" — we do,
it's `fly logs`. (If we ever add Sentry, update this section; until then `fly logs`
is the source of truth.)

```sh
# Tail the live error stream (all app machines). DB errors surface here as
# Postgrex/Ecto exceptions with the SQLSTATE (e.g. 57014 = statement_timeout).
fly logs -a loopctl

# Narrow to one machine, or grep a known marker / request_id after reproducing:
fly logs -a loopctl -i <machine-id>
fly logs -a loopctl | grep -iE "timeout|57014|db_statement_timeout|ERROR"
```

To reproduce the failing request against the live build, hit the deployed endpoint
with the **reported repro ids/params** (the same ones on the issue) and watch the
log stream for the exception:

```sh
curl -sS -H "Authorization: Bearer $LOOPCTL_KEY" \
  "https://loopctl.com/api/v1/knowledge/<endpoint>?<repro-params>" -o /dev/null -w '%{http_code}\n'
```

> **`$LOOPCTL_KEY` must be an API key for the SAME tenant on the issue.** Requests are
> RLS-scoped: a key for the wrong tenant returns `404`/empty (not the timeout), so
> "confirming 200" with a mismatched key is itself a false-green. Use a read-scoped key
> for the repro tenant (mint via the dispatch pattern / an existing tenant API key), not
> a write/orchestrator key.
>
> **`fly` access** (`fly logs`, `fly ssh console`) requires operator CLI auth (the
> operator's Fly account). If you don't have it, hand the `fly logs` / live `EXPLAIN`
> steps to an operator — do NOT close the issue on the local gate alone.

A statement timeout surfaces as a **`504` with code `db_statement_timeout`** (US-27.4
maps SQLSTATE `57014` → 504; see `lib/loopctl_web/db_error.ex`). A generic `500`
`db_error` is the catch-all for an *unmapped* SQLSTATE and does **not** carry the
`db_statement_timeout` code — so a timeout is specifically a 504, not a 500. Either,
with the matching exception in `fly logs`, is the real prod error. **Capture it on the
issue** before claiming a fix.

---

## Verifying at scale

Two layers: (1) a **representative-scale corpus** with plan assertions in CI/local,
and (2) a **live `EXPLAIN ANALYZE`** on the deployed build. Both are required — the
staging corpus is an approximation (the ~80k `ScaleSeed.prod_article_floor` vs the 76k+
growing prod corpus and prod's
ANALYZE stats), so the live step is never optional.

### The scale gate (representative corpus + plan assertions)

The gate is the `:scale_nightly`-tagged suite run against a committed, ANALYZEd
~80k-row corpus (`Loopctl.Knowledge.ScaleSeed`, US-27.1) with the US-27.2 plan
assertions (`Loopctl.PlanAssertions`). It exercises every heavy endpoint's plan at
prod scale — the vector ANN path, the enumeration/keyset path, and the shared
plan-assertion suite — under the planner's **natural** choice (no `enable_seqscan=off`),
which is the distinction that produced the false-green in #172.

**What the gate asserts (be precise — the gate's value is knowing exactly what it covers):**
- **Plan shape at scale** — index-backed, no full-corpus Seq Scan — for the vector ANN
  (`vector_search_scale_test.exs`), the enumeration/keyset path
  (`keyset_plan_scale_test.exs`), and the shared assertions (`plan_assertions_scale_test.exs`).
- **Per-request timeout at scale** — the worst-case ANN and the deep keyset page must
  EXECUTE under the heavy-read pool `statement_timeout` backstop (US-27.4). NB: this is
  the **pool-level** backstop on those two endpoints. The per-endpoint `statement_timeout`
  **overrides** (`:heavy_read_statement_timeout_overrides`) are unit-tested
  (`heavy_read_statement_timeout_test.exs`), NOT scale-tested — the scale gate covers the
  backstop that actually protects prod, not every override permutation.
- **Per-endpoint index-usage + END-TO-END latency (US-27.8)** — every vector path
  (`suggested_links`, `semantic` search results + count, `distant_pairs`, `novelty`, AND
  the auto-link worker) carries an 80k index-usage gate on its REAL request-path query
  (`topk_endpoints_scale_test.exs`, `distant_pairs_novelty_scale_test.exs`), plus an
  ADVISORY end-to-end wall-clock budget measured through the real HTTP conn
  (`vector_endpoint_e2e_latency_scale_test.exs`, `:scale_latency_budget_ms` default 2000ms).
  Calibration is asserted, not assumed: a sub-floor seed or `ef_search` mismatch FAILS
  loudly (`scale_calibration_mismatch_scale_test.exs`) — and the `ef_search` failure
  direction now drives a REAL `SET LOCAL hnsw.ef_search` session divergence (read back via
  `SHOW`), not a synthetic string compare, so the parity gate is proven against the actual
  pgvector GUC. See the **Standing vector-endpoint CI gates (US-27.8)** section of
  [`knowledge-scale.md`](knowledge-scale.md) for the lint guard, the latency-budget/seed-floor
  knobs, and the floor-bump step.
  - **PARTIAL COVERAGE (AC-27.8.4) — know exactly what the e2e timing does NOT cover.** In
    `:test` the heavy-read DI routes through `AdminRepo`, NOT the dedicated `HeavyReadRepo`
    pool, so the `vector_endpoint_e2e_latency_scale_test.exs` wall-clock does **not** exercise
    the heavy-pool checkout / pool-level `statement_timeout` dimension. That dimension is
    covered SEPARATELY by the per-request-timeout assertions on the worst-case ANN and deep
    keyset page (the bullet above; `topk_endpoints_scale_test.exs`). The e2e test's distinct
    value is the full HTTP path (auth → RLS context → query → serialize → render) wall-clock;
    do not read a green e2e budget as evidence the heavy pool behaves under load — that is the
    timeout bullet's job.
- **No cosine-`<=>` reintroduction (US-27.8, the `lint` job)** — `mix credo --strict` runs
  the `Loopctl.Credo.Check.CosineQueryReintroduction` custom check, which fails the build
  if a NEW hand-rolled cosine `<=>` appears in `lib/loopctl` outside
  `Loopctl.Knowledge.VectorSearch` and not in the `Loopctl.Knowledge.CosineLintExceptions`
  allowlist. The allowlist exempts the LINT location only — never a bad SHAPE from the plan
  gate above.

It runs in two places:

- **CI, on MANUAL DISPATCH ONLY** (`.github/workflows/ci.yml`, job `Scale Nightly` — the
  name predates the trigger change). `gh workflow run CI --ref <branch>` is the pre-merge
  gate and the ONLY thing that starts this matrix. **It runs on no cron at all** — not the
  02:00 one the rest of CI uses, and not any other. So plan drift that arrives with no PR
  (a Postgres/pgvector upgrade, an ANALYZE shift) is NOT caught automatically: dispatch the
  matrix yourself after any such infrastructure change. It is a **matrix — one isolated job per scale file**, each
  on its own database (`loopctl_test_sn_<file>`, derived in the job; beelink has one
  long-lived Postgres, and planner stats live in the per-database `pg_statistic`) so a
  committed-row corpus from one file can't pollute another's global planner stats. A
  failed drop step leaves that database behind — reclaim it by hand.
  Each leg runs `SCALE_TESTS=true SCALE_NIGHTLY=true mix test --only scale_nightly <file>`.
  The matrix covers **every `:scale_nightly`-tagged file** (the US-27.1 seed-floor check, the
  HNSW ANN / keyset / shared-assertion plan gates, and the US-27.8 per-endpoint index-usage,
  e2e-latency, and calibration-mismatch gates). The exact list is NOT enumerated here on
  purpose — it is kept in lock-step with the tagged files by `scale_verification_runbook_test.exs`
  (set-equality, both directions), so this prose can't go stale as files are added.
- **Don't confuse the per-PR `Scale Tests` job with the `:scale_nightly` plan GATE (E3).** A separate
  job, **`Scale Tests (US-27.1)`**, DOES run on every push/PR — but it runs only
  `--only scale .../scale_seed_test.exs`: it proves the seed/fixture machinery (and its
  `OwnershipError`-class regressions) still works, NOT the 80k planner paths. The
  `:scale_nightly` plan gate (index-backed shape, per-request timeout, e2e latency,
  calibration) is **dispatch-only** — a green `Scale Tests ✓` on your PR is **not**
  evidence the plan gates ran, and neither is "it will run overnight": there is no
  automatic run, ever. Tag discipline: a new 80k plan assertion must be `:scale_nightly`
  (so the matrix + set-equality test pick it up), not `:scale`.
- **Before merging any Theme 2/3/4 (vector / timeout / pagination) PR** — the plan gate never
  runs on your PR (each leg reseeds ~80k committed rows — too slow for every PR, and there
  is no always-on staging env), so a perf PR is verified pre-merge by EITHER:
  1. **triggering the gate on your branch** — `gh workflow run CI --ref <your-branch>`
     (the `workflow_dispatch` trigger runs the full matrix on the branch; confirm EVERY
     leg goes green), OR
  2. **running it locally** against the seed:

  ```sh
  # Reset first — scale tests COMMIT rows (unboxed) that otherwise pollute later runs.
  MIX_ENV=test mix ecto.reset
  SCALE_TESTS=true SCALE_NIGHTLY=true mix test --only scale_nightly
  # …or just the file you touched, e.g. the keyset plan gate:
  SCALE_TESTS=true SCALE_NIGHTLY=true mix test --only scale_nightly \
    test/loopctl/knowledge/keyset_plan_scale_test.exs
  MIX_ENV=test mix ecto.reset   # leave the DB clean for the normal suite
  ```

  This pre-merge run is **required**, not optional, for a query/index change. Nothing in CI
  can enforce it — there is no status check for "you dispatched the matrix", so the reviewer
  asks for the run id. Nothing else will tell you, before merge or after.
  (Likewise: any change to the `scale-nightly`
  matrix job itself must be `workflow_dispatch`-validated on its branch before merge,
  since the job does not run on the PR.)

The plain `mix test` suite **always excludes** `:scale` and `:scale_nightly`
(`test/test_helper.exs`), so the gate never slows the default unit run.

### Live `EXPLAIN ANALYZE` on the deployed build

CI proves the plan on a *seeded* corpus; this proves it on the *real* one with prod's
stats, on the *currently deployed* release. loopctl has no Sentry but it has a remote
console — use the release `rpc` (the bin is `/app/bin/loopctl`):

Build `q` from the SAME query builder the endpoint and the scale tests use — e.g.
`Loopctl.Knowledge.keyset_query/2` (enumeration) or the `Knowledge.*_query` /
`suggestion_candidates_query` builders (vector) — so you EXPLAIN the real request path,
not a hand-written approximation.

```sh
fly ssh console -a loopctl -C "/app/bin/loopctl rpc '
  import Ecto.Query
  # q MUST carry an explicit tenant_id filter (see caution below).
  q = Loopctl.Knowledge.keyset_query(\"<tenant-uuid>\", status: :published, cursor: nil, limit: 21)
  IO.puts(Loopctl.AdminRepo.explain(:all, q, analyze: true))
'"
```

> **⚠ `AdminRepo` is the BYPASSRLS repo.** It does NOT enforce tenant isolation. Every
> probe query MUST carry an explicit `tenant_id` filter, and use it for `explain` only —
> never adapt this block into an `AdminRepo.all` data read, which would read across
> tenants. Scrub tenant slugs / `request_id`s from any `fly logs` output before pasting
> it onto a public issue.

Read the plan the SAME way the assertions do: the relation must be reached by an
**Index Scan** on the expected index (HNSW for ANN, the `(tenant_id, inserted_at, id)`
btree for keyset), NOT a `Seq Scan` / `Parallel Seq Scan` / full-corpus `Bitmap Heap
Scan`. Confirm the `Execution Time` is **under the endpoint's `statement_timeout`**
(US-27.4; default 10s on the heavy pool). A plan that's index-backed in CI but
Seq-Scans in prod (different stats) is exactly the #172 trap — that's why this step
exists.

---

## Closing checklist

A scale/perf issue is **NOT "verified-in-prod"** until ALL of these pass. Paste the
evidence (plan excerpts, timings, HTTP codes) onto the issue/PR before closing:

- [ ] **Plan-assertion green at scale** — the relevant `:scale_nightly` gate test
      passes against the ~80k `ScaleSeed` corpus — locally, or via a manual
      `gh workflow run CI --ref <branch>` (the matrix is dispatch-only, on no cron,
      so a green PR is never evidence it ran).
- [ ] **`EXPLAIN ANALYZE` under the timeout on the LIVE build** — the deployed
      release's plan for the exact endpoint query is index-backed and its
      `Execution Time` is below the endpoint `statement_timeout` (US-27.4).
- [ ] **The live endpoint returns 200 on the reported repro ids** — the original
      failing request (same ids/params from the issue) now succeeds against
      `https://loopctl.com`, confirmed by HTTP status + a clean `fly logs`.

"CI is green and the PR merged" satisfies **none** of these on its own. If a true
staging environment is ever stood up, the minimum gate stays the same: the scale
fixture in CI **plus** the live prod `EXPLAIN`/logs confirmation.

---

## Index drift

> **Which index serves reads is now install-dependent (GH #578).** The ANN read path
> moved to the `article_embeddings` side table on 2026-07-22, gated on
> `SystemConfig "embedding_side_table_reads"`. On a **cut-over** install (prod) the live
> index is `article_embeddings_hnsw_dim_<dim>_idx` and the legacy
> `articles_embedding_hnsw_idx` has been retired; on an install still reading the legacy
> column — the shipped default, since the flag defaults to `0` in code and no migration
> seeds the row — the legacy index is **deliberately kept**, and
> `20260805120000_drop_legacy_articles_embedding_hnsw_index.exs` skips its drop there.
> Check the flag before concluding a missing index is drift:
>
> ```sql
> SELECT value FROM system_configs WHERE key = 'embedding_side_table_reads';
> ```
>
> Everything below is about detecting whichever HNSW index an install DOES have. The
> capability-detection rule is unchanged and is the reason a name-based check would have
> read the #578 retirement as a broken deploy.

The HNSW index on `articles(embedding)` exists under **two names** historically: the
migration created `articles_embedding_idx`, but the **live prod index was created
out-of-band as `articles_embedding_hnsw_idx`**. This drift is a known foot-gun (see
US-27.14 for the reconcile-vs-tolerate decision and the down-migration no-op hazard;
the reconcile migration is `20260624120000_reconcile_hnsw_index_name.exs`).

**Detect the index by CAPABILITY, never by hard-coded name.** A name check
(`indexname = 'articles_embedding_idx'`) silently misses the live `_hnsw_idx`:

```sql
-- Canonical capability-based detection (access method, not name):
SELECT i.relname
FROM pg_class t
JOIN pg_index ix ON ix.indrelid = t.oid
JOIN pg_class i  ON i.oid = ix.indexrelid
JOIN pg_am am    ON am.oid = i.relam
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE t.relname = 'articles' AND n.nspname = 'public' AND am.amname = 'hnsw';

-- Equivalent ad-hoc form when eyeballing \d output:
SELECT indexname FROM pg_indexes
WHERE tablename = 'articles' AND indexdef ILIKE '%hnsw%';
```

**⚠ The silent no-op hazard:** `DROP INDEX IF EXISTS articles_embedding_idx` run
against prod **does nothing** — the live index is named `articles_embedding_hnsw_idx`,
so `IF EXISTS` matches nothing and the real HNSW index survives a rollback that
*looks* like it dropped it. The HNSW migration's own down-step has **already been
remediated** to detect by `amname='hnsw'` (US-27.14;
`20260410022906_add_embedding_hnsw_index.exs` + `20260624120000_reconcile_hnsw_index_name.exs`),
so this is the *rationale* for the capability-detection rule, not an open bug in the
migrations — but the trap still bites any ad-hoc `psql` `DROP` you type by name.
Always drop/inspect HNSW indexes by `amname='hnsw'` detection, not by an assumed name.

**The one place a name is correct is the #578 retirement**, and only because it is
paired with a validity check. `DROP INDEX CONCURRENTLY` cannot run inside a `DO` block,
so the retirement names `articles_embedding_hnsw_idx` directly — which is safe *there*
because US-27.14 already reconciled every environment onto that name. When verifying
the outcome, assert on `pg_index.indisvalid` and the EXPLAIN plan node, never on
`pg_indexes` name presence: `pg_indexes` lists INVALID indexes too, and
`ORDER BY embedding <=> $1 LIMIT k` returns k rows identically with or without an index.
On a cut-over install the plan must read
`Index Scan using article_embeddings_hnsw_dim_<dim>_idx`.
The same `IF NOT EXISTS`/`IF EXISTS` name-blindness applies to the keyset index
recovery in
[`knowledge-scale.md`](knowledge-scale.md) — verify with `pg_index.indisvalid`, not by
name presence.
