# Epic 27 — Knowledge Subsystem Performance & Scale Hardening

Decomposition of GitHub Epic **#175** (+ export issue **#176**) into 20 user stories.
Authored with the `user-story-writer` skill and refined through **two rounds of multi-agent
enhanced review** (Opus analyst / architect / adversarial), every finding verified against the
live code.

## How to implement (autonomous, zero manual intervention until the end)

```
/implement-plan --epic docs/user_stories/epic_27_knowledge_scale_hardening
```

Epic mode reads these story JSONs, **topologically sorts by each story's `dependencies`**, and drives
each through an un-skippable cycle: implement → 7-agent enhanced review → zero-deferrals fix →
`mix precommit` gate → CI-gated squash-merge → next. WIP=1, dependency-blocked. **No separate plan
doc is needed** — this folder is the input.

### Quality gates — none are sacrificed; scale/prod verification is deferred to the end

Gates split into two kinds:

| Gate | When it runs | Automatable mid-loop? |
|------|--------------|-----------------------|
| `mix precommit` (async unit suite) | every story | ✅ yes (the loop's merge gate) |
| 7-agent enhanced review + zero-deferral fix | every story | ✅ yes |
| CI checks (Lint/Security/Dialyzer/Test/GitGuardian) | every PR | ✅ yes |
| `@tag :scale` suite (committed ~80k corpus) | **terminal story US-27.17** | ⛔ excluded from `mix precommit` |
| Prod live-build verification (fly EXPLAIN / repro ids / logs) | **terminal story US-27.17** | ⛔ needs the deployed build |

The `@tag :scale` tests and the prod checks are **excluded from `mix precommit` by design**, so the
loop never blocks on them — every implementation story (27.1–27.16) merges on code + unit + review +
CI. The deferred verification is **owned and executed by US-27.17**, which runs DEAD LAST (it depends
on every leaf story): it seeds the ~80k corpus, runs the whole `@tag :scale` suite epic-wide,
remediates any scale failure, and runs the prod EXPLAIN/repro-id/log checks **autonomously via the
authenticated `fly` CLI** (the proven #172 method). The operator's only involvement is **reviewing the
final report** — never a mid-stream gate.

> Alternative (heavier, per-PR scale enforcement): wire the scale suite into CI as a job and run with
> `--gate "mix precommit && SCALE_TESTS=1 mix test --only scale"`. Costs an ~80k seed per PR; the
> US-27.17 terminal model is the lighter, autonomy-first default.

### Before launching — one thing to confirm

The WIP=1 loop auto-merges each PR once CI is green. It only **stalls** if the base branch
(`master`) requires a **human PR approval** (`required_approving_review_count > 0`). loopctl's
`master` has required *checks* but not required *approvals* (PRs this session merged without human
approval), so the loop should run unattended. If that changes, pass `--auto` and expect a per-PR
approval, or relax the approval requirement.

## Topological build order (what the loop will follow)

```
27.14 → 27.1 → 27.3 → 27.11 → 27.2 → 27.12 → 27.4 → 27.9a → 27.6a → 27.5 →
27.10 → 27.16 → 27.9b → 27.7b → 27.6b → 27.7a → 27.15 → 27.8 → 27.13 → 27.17
```
(Note: dependency order, not numeric — e.g. 27.11 is built before 27.4 because 27.4's
statement_timeout mechanism depends on the pool work.)

## Stories by theme

- **Theme 1 — scale testing + observability:** 27.1 fixture · 27.2 plan-assertion (real query, no forced planner) · 27.3 SQLSTATE→structured errors · 27.4 statement_timeout + slow-query log · 27.5 staging gate + prod runbook
- **Theme 2 — index-correct vector layer:** 27.6a/6b kNN helper + recall/under-fill · 27.7a/7b migrate (and the `distant_pairs`/`novelty` non-fits) · 27.8 per-endpoint index + latency gates
- **Theme 3 — cursor pagination:** 27.9a/9b keyset + integrity + rollout · 27.10 cursor contract + bounded `include_body`
- **Theme 4 — pool + bulk:** 27.11 pool sizing / heavy-read pool · 27.12 set-based bulk (FK-`:restrict`-correct, atomic, bounded)
- **Cross-cutting:** 27.13 remediation · 27.14 HNSW index-name reconcile (decided) · 27.15 telemetry/alerting · 27.16 streamed export (#176) · **27.17 terminal scale + prod verification**

Grounding incidents across the set: the 4-attempt `suggested_links` saga, the `enable_seqscan=off`
false-confidence trap, the 3-conn pool starvation, the ~4,000-DELETE cleanup, the 5,000-article
export cap. Tenant-isolation ACs on every BYPASSRLS path; prod-verification consolidated in US-27.17.
