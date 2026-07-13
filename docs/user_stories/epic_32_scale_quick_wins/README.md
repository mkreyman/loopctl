# Epic 32 — Scalability Quick Wins

The low-effort, high-impact first batch of the [Scalability Remediation Roadmap](../../../) — GitHub issue **#354**, tracked under **#355**. Each is a config / index / small-code change that de-risks the "one heavy agent" incident and/or is a prerequisite for a later epic.

## Scope reconciliation (verified against live code before authoring)

Issue #354 listed 8 quick wins; grounding against the current `master` found 3 already handled:

| #354 item | Status | Evidence |
|-----------|--------|----------|
| 1. Oban Lifeline | ✅ done (#323) | `config/config.exs` `{Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}` |
| 2. Oban Pruner | ✅ done (#323) | `config/config.exs` `{Oban.Plugins.Pruner, max_age: 7d}` |
| 8. DNS_CLUSTER_QUERY | ⚙️ code wired; Fly secret only | `application.ex` + `runtime.exs` read it — folded into Epic 6 (scale-out gate) |

The remaining 5 are the stories below.

## Stories

| Story | Title | #354 item | Depends |
|-------|-------|-----------|---------|
| US-32.1 | Partial index `dispatches(expires_at) WHERE revoked_at IS NULL` | 3 | — |
| US-32.2 | Oban queue widths → `runtime.exs` env vars | 4 | — |
| US-32.3 | ETS-cache tenant LLM settings (bust on `set_llm_config`) | 5 | — |
| US-32.4 | Fail loud when scale alerts enabled but URL unset | 6 | — |
| US-32.5 | STH fanout `Oban.insert_all` + jitter | 7 | — |

All five are independent (distinct files), so WIP=1 order is not constrained.

## Non-negotiable constraint

loopctl is **live**, with agents actively doing KB retrieval. No story may cause an outage:
- Every merge auto-deploys; the post-deploy **smoke suite gates each deploy** and KB retrieval health is checked before/after.
- The one migration (US-32.1) is **online** (`CONCURRENTLY`, `@disable_ddl_transaction`).
- Config changes (US-32.2/32.4) default to current behavior when env is unset.
