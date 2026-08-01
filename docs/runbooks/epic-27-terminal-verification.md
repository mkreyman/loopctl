# Epic 27 — Terminal Verification Report (US-27.17)

The single, end-of-epic consolidated verification pass. Per US-27.17, the `@tag :scale`
suite (needs a committed ~80k corpus + a non-sandbox DB) and the prod live-build checks
(need the deployed build + fly) are deferred from per-story merges and executed **once**,
comprehensively, here — so the epic builds autonomously with no manual gate mid-stream while
every quality gate is still honored.

**Verdict: GREEN on both the scale gate and prod.** One scale failure was found and
remediated in this pass (no deferral, AC-27.17.2).

**Evidence:** the `:scale_nightly` matrix ran at 80k in CI `workflow_dispatch` — the master
run (`28211756602`) was green on all legs EXCEPT `remediation_matrix` (the by_source failure
below), and the fix's re-run on commit `d561ad4` (`workflow_dispatch` run `28212651418`)
turned the `remediation_matrix` leg green with every other leg green (incl. `streaming_export`,
confirmed green on the master run). So every leg is green across the two runs, with the one
failing leg re-run green on the fix.

Run date: 2026-06-26. Deployed prod build: loopctl `v159+` (US-27.13 fix, `prepare: :unnamed`,
per-read `SET LOCAL` heavy-read timeout).

---

## AC-27.17.1 — Full scale gate matrix (≥ prod floor, with calibration provenance)

The entire `:scale_nightly` matrix was run in CI (`gh workflow run CI` — every scale file in
an isolated job with a fresh Postgres, seeded to `ScaleSeed.prod_article_floor()` = **80,000**
committed rows).

**Calibration provenance:** seed_count = 80,000 ≥ prod_floor 80,000; effective
`hnsw.ef_search` = `40` (pgvector default; the under-fill + calibration-mismatch gates assert
gate-vs-prod parity). The remediation-matrix census records this provenance and refuses to
certify an uncalibrated run (AC-27.13.4a).

| Scale gate (`:scale_nightly`) | Result |
|---|---|
| `scale_seed_nightly_test.exs` (US-27.1 seed/floor) | ✅ pass |
| `plan_assertions_scale_test.exs` (US-27.2 shared) | ✅ pass |
| `vector_search_scale_test.exs` (HNSW ANN) | ✅ pass |
| `vector_search_under_fill_scale_test.exs` (US-27.6b + ef_search parity) | ✅ pass |
| `topk_endpoints_scale_test.exs` (suggested_links / semantic / worker, US-27.7a/27.8) | ✅ pass |
| `distant_pairs_novelty_scale_test.exs` (US-27.8) | ✅ pass |
| `vector_endpoint_e2e_latency_scale_test.exs` (US-27.8 advisory) | ✅ pass |
| `cosine_lint_vs_scale_gate_scale_test.exs` (US-27.8) | ✅ pass |
| `scale_calibration_mismatch_scale_test.exs` (US-27.8 fail-loud) | ✅ pass |
| `keyset_plan_scale_test.exs` (US-27.9a) | ✅ pass |
| `by_source_change_feed_plan_scale_test.exs` (US-27.9b) | ✅ pass |
| `streaming_export_scale_test.exs` (US-27.16 memory bound) | ✅ pass |
| `remediation_matrix_scale_test.exs` (US-27.13 census) | ✅ pass *(after the AC-27.17.2 fix below)* |

The keyset deep-page assertions (US-27.9a/9b) are exercised within the keyset/by-source/
change-feed files above. Every per-endpoint plan gate is index-backed at 80k under the
planner's NATURAL choice (no `enable_seqscan=off`) — the distinction that produced the #172
false-green.

**Scope note (honest):** the bulk archive/delete blast-radius (US-27.12) is NOT a
`:scale_nightly` gate — it is a SET-BASED query-correctness concern (one bounded
`UPDATE/DELETE … WHERE`, tenant-scoped, no row-by-row N+1), fully verified by
`bulk_ops_test.exs` in the DEFAULT suite (every `mix precommit` + per-PR CI), so it does not
need an 80k corpus. It is recorded here for completeness, not run in the scale matrix.

---

## AC-27.17.2 — Remediation of the scale failure found in this pass

The terminal pass caught the ONE failure the per-PR CI structurally cannot (the
`:scale_nightly` matrix is dispatch-only, so a scale test merges on code+unit+review
without ever running in per-PR CI):

- **`remediation_matrix`'s `by_source_keyset` endpoint** failed in CI's planner while passing
  locally. `refute_full_scan` rejected a **bounded** Bitmap Heap Scan (~80 published rows via
  the selective `source_id` index + a Sort; CI's `Plan Rows` under-estimated this at 24) that
  CI's pg16 chose on the FIRST page (`cursor: nil`), where local PG chose an Index Scan — a
  cost-marginal planner difference, both plans correct for a ~1-of-800 `source_id =` equality.
  (The dedicated by-source gate keeps `refute_full_scan` correctly — its DEEP cursor predicate
  forecloses the bitmap; the difference is the cursor, not stats, so that gate is not at risk.)
- **Fix (commit `d561ad4`, hardened in review):** assert the planner-agnostic invariant —
  `refute_seq_scan` (no unbounded scan; covers Parallel Seq Scan) + `assert_actual_scan_rows_below(div(floor, 8))`
  (ACTUAL rows via EXPLAIN ANALYZE, not the planner estimate — closing the bitmap
  low-estimate/high-actual blind spot) — instead of `refute_full_scan`. The same hardening was
  applied to `by_tag_keyset` for parity. No deferral; remediated in this pass and re-run green.

---

## AC-27.17.3 — Prod live-build verification (autonomous, via fly)

Run against the deployed build (tenant `0abd22c2…`, the real ~76,873-embedded-article prod
corpus) via `fly ssh console … rpc` — `AdminRepo.explain(:all, q, analyze: true)` on each
heavy endpoint's REAL request-path query builder:

| Endpoint (prod) | Full Seq Scan on `articles`? | Index reached | Exec time |
|---|---|---|---|
| `suggested_links` (`suggestion_candidates_query`) | no | `articles_embedding_hnsw_idx` | 13 ms |
| `search_semantic` results (`semantic_results_query`) | no | `articles_embedding_hnsw_idx` | 2.7 ms |
| `search_semantic` count (`semantic_count_query`) | yes — **expected** ¹ | (count, no Sort ²) | 1.66 s |
| `keyset` enumeration (`keyset_query`) | no | `articles_tenant_inserted_id_idx` | 0.1 ms |
| `distant_pairs` (`distant_pairs/1`) | no (bounded sample) | — | 7.9 s ³ |
| `novelty` (`novelty_scores`) | no (tag-bounded) | — | 1.4 s |

¹ An UNFILTERED `count(*)` over the tenant's 76k published rows is inherently O(rows) — a
bounded tenant scan is the correct plan; there is no index-only count for an arbitrary filter.
² The regression the gate guards (the pre-27.7a pointless full-corpus **Sort** wrapping the
ORDER BY) is ABSENT — verified `Sort`-free in prod. ³ Bounded by the
`LIMIT max_pair_candidates` sampled subquery; under the 10s heavy-read `statement_timeout` (the
slowest heavy endpoint — worth watching as the corpus grows).

- **Repro / correctness:** `Knowledge.suggest_links_with_meta/3` (the exact function the
  controller JSON-encodes) returns `{:ok, [5 suggestions], meta}` in ~40–113 ms on the repro
  target — the live "200 with correct results" for the historically-broken endpoint.
- **`fly logs` scan:** **zero** `57014` / `db_statement_timeout` / `query_canceled` /
  `unsupported startup parameter` errors in the post-deploy window.
- **Heavy pool health:** `HeavyReadRepo.query("SELECT 1")` = 3–6 ms (was a 14 s queue timeout
  before the US-27.13 fix); zero prepared-statement `26000`/`42P05` errors with
  `prepare: :unnamed` live.

---

## AC-27.17.4 — Deferred-AC execution map

| Deferred AC (story) | Where verified here | Result |
|---|---|---|
| Per-endpoint plan @ 80k (US-27.2/27.8) | scale matrix (topk, distant_pairs, vector_search) | ✅ |
| Keyset deep-page (US-27.9a/9b) | keyset + by_source/change-feed gates | ✅ |
| Bulk blast-radius (US-27.12) | `bulk_ops_test.exs` (default suite — set-based correctness, not a scale gate) | ✅ |
| Export memory bound (US-27.16) | streaming_export gate | ✅ |
| Calibration fail-loud (US-27.8) | scale_calibration_mismatch | ✅ |
| Remediation census (US-27.13) | remediation_matrix (+ AC-27.17.2 fix) | ✅ |
| Prod EXPLAIN under timeout (US-27.5) | AC-27.17.3 table | ✅ |
| Prod repro 200 (US-27.5/27.13) | suggest_links_with_meta live | ✅ |
| Prod log scan for 57014 (US-27.5) | AC-27.17.3 fly logs | ✅ |

---

## AC-27.17.5 — Prod reachability

Prod WAS reachable from the run context (authenticated `fly` CLI), so AC-27.17.3 ran
autonomously — no manual operator touch was required. (Had it been unreachable, the scale
portion above would still complete and this report would flag only AC-27.17.3 as the single
remaining 5-minute operator confirmation.)

**Epic 27 is verified: all-green on both the scale gate and prod.**
