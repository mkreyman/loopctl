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
staging corpus is an approximation (a 50–100k seed vs the 76k+ prod corpus and prod's
ANALYZE stats), so the live step is never optional.

### The scale gate (representative corpus + plan assertions)

The gate is the `:scale_nightly`-tagged suite run against a committed, ANALYZEd
~80k-row corpus (`Loopctl.Knowledge.ScaleSeed`, US-27.1) with the US-27.2 plan
assertions (`Loopctl.PlanAssertions`). It exercises every heavy endpoint's plan at
prod scale — the vector ANN path, the enumeration/keyset path, and the shared
plan-assertion suite — under the planner's **natural** choice (no `enable_seqscan=off`),
which is the distinction that produced the false-green in #172.

It runs in two places:

- **CI nightly** (`.github/workflows/ci.yml`, job `Scale Nightly`): on the 02:00 UTC
  schedule, `SCALE_TESTS=true SCALE_NIGHTLY=true mix test --only scale_nightly`. This
  runs **all** `:scale_nightly` tests — `scale_seed_nightly_test.exs`,
  `vector_search_scale_test.exs`, `plan_assertions_scale_test.exs`, and
  `keyset_plan_scale_test.exs` — not just one file.
- **Locally, before merging any Theme 2/3/4 (vector / timeout / pagination) PR** — the
  gate is nightly-only in CI (an 80k seed is too slow for every PR and there is no
  always-on staging env), so a perf PR is **verified locally** against the seed before
  merge:

  ```sh
  # Reset first — scale tests COMMIT rows (unboxed) that otherwise pollute later runs.
  MIX_ENV=test mix ecto.reset
  SCALE_TESTS=true SCALE_NIGHTLY=true mix test --only scale_nightly
  # …or just the file you touched, e.g. the keyset plan gate:
  SCALE_TESTS=true SCALE_NIGHTLY=true mix test --only scale_nightly \
    test/loopctl/knowledge/keyset_plan_scale_test.exs
  MIX_ENV=test mix ecto.reset   # leave the DB clean for the normal suite
  ```

The plain `mix test` suite **always excludes** `:scale` and `:scale_nightly`
(`test/test_helper.exs`), so the gate never slows the default unit run.

### Live `EXPLAIN ANALYZE` on the deployed build

CI proves the plan on a *seeded* corpus; this proves it on the *real* one with prod's
stats, on the *currently deployed* release. loopctl has no Sentry but it has a remote
console — use the release `rpc` (the bin is `/app/bin/loopctl`):

```sh
fly ssh console -a loopctl -C "/app/bin/loopctl rpc '
  import Ecto.Query
  q = <the exact query the endpoint builds>
  IO.puts(Loopctl.AdminRepo.explain(:all, q, analyze: true))
'"
```

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
      passes against the ~80k `ScaleSeed` corpus (locally and/or in the nightly job).
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
The same `IF NOT EXISTS`/`IF EXISTS` name-blindness applies to the keyset index
recovery in
[`knowledge-scale.md`](knowledge-scale.md) — verify with `pg_index.indisvalid`, not by
name presence.
