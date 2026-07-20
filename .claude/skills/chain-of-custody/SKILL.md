---
name: chain-of-custody
description: Use when changing anything in loopctl's trust model — role requirements, the auth pipeline, story lifecycle transitions (report / review-complete / verify), capability tokens, dispatch lineage, WebAuthn/human-anchor gates, or the audit chain. Covers who may do what, why the self-* 409s are correct, and the capability/dispatch mechanics. Triggers on: chain of custody, self_report_blocked, self_review_blocked, self_verify_blocked, RequireRole, role hierarchy, capability token, dispatch, lineage, WebAuthn, human anchor, custody halt, superadmin, orchestrator, agent role, verify_story, report_story.
---

# Chain of Custody & Trust Model

loopctl's core product guarantee: **nobody marks their own work as done.** An agent implements, an
*independently-lineaged* verifier confirms. Weakening any custody gate is the single most dangerous
change class here. Full spec: `docs/chain-of-custody-v2.md` (Epic 26). This skill is the code map +
invariants — read the cited code and the spec before touching auth/custody.

## Role hierarchy — `superadmin (4) > user (3) > orchestrator (2) > agent (1)`

Ranks (`@role_levels`, `:12`) and `role_at_least?/2` (`:34`) live in `lib/loopctl/auth/role.ex`; enforcement is the
`LoopctlWeb.Plugs.RequireRole` plug (`lib/loopctl_web/plugs/require_role.ex`). Higher roles inherit
lower-role endpoints. Human-rooted operations additionally pass `RequireHumanAnchor`
(`lib/loopctl_web/plugs/require_human_anchor.ex`), which gates on the TENANT's `trust_tier` and is
**deliberately orthogonal to role** (`:4`, `:9`): `:human_anchored` passes (`:51`), `:agent_rooted` halts
with `403 custody_tier_required` (`:61`). It is not a per-request WebAuthn check — WebAuthn is how a
tenant EARNS `:human_anchored`. Keying on tier rather than role is what closes the self-minted-key bypass.

**Where the line sits (CLAUDE.md "Security & Trust Model" checklist — the authority):**
- `role: :user` (or WebAuthn): anything IRREVERSIBLE or that is itself a custody gate — tenant/project
  delete, budget/token corrections, cost-anomaly resolution, audit-key rotation, break-glass. On the KB
  surface the gate is **set-based blast radius, not hard-delete-ness**: `unpublish`, `bulk_publish`,
  `bulk_unpublish` and ALL of `bulk_delete` (soft path included) are `:user`
  (`article_workflow_controller.ex:36-39`).
- `role: :orchestrator`: constructive/metadata work-breakdown (create/update epics, stories, deps,
  imports, backfills) so an autonomous orchestrator composes projects without a human.
- `role: :agent`: read work-breakdown only; **KB-content curation is the carve-out** — create/update/
  soft-archive/resolve-conflict are agent-role because each is reversible + audited (see `knowledge-wiki`).

Rule of thumb before lowering any role: *does this let one session both implement AND verify/report?*
If yes, the change is wrong.

## The self-* gates — the 409s are the system working

Enforced in `lib/loopctl/progress.ex`. **The three gates are NOT one implementation — only `verify` is
lineage-aware today.** Do not assume otherwise when reasoning about custody strength:

- **verify** — `validate_not_self_verify/2` `progress.ex:1612-1648`. Compares implementer vs verifier
  **dispatch lineage** via `Dispatches.lineage_shares_prefix?/2` (`:1631-1639`); a shared prefix ⇒
  `:self_verify_blocked`. `nil` orchestrator identity is untrusted (`:1613`); a custody-orphaned story
  fails closed with `:missing_assigned_agent` (`:1626-1628`, "nil is never permissive"); `assigned_agent_id`
  equality is only the pre-dispatch fallback (`:1642`). **Only here** does a sub-agent dispatched BY the
  implementer get blocked despite carrying a different `agent_id`.
- **report** — `validate_not_self_report/2` `progress.ex:2107-2128`. `nil` blocked (`:2107`), then plain
  `assigned_agent_id` equality (`:2116`, `:2122`). Lineage is computed at `:2113` and **discarded** —
  see the `:2114-2115` comment, reporter dispatch isn't tracked yet.
- **review-complete** — `validate_not_self_review/2` `progress.ex:2130-2165`. Custody-orphan backstop
  first (`:2137-2139`), then a **`nil` reviewer is deliberately PERMITTED** (`:2146-2147`) because nil
  means a human operator on a user-role key; the controller requires agent/orchestrator keys to supply a
  real `reviewer_agent_id`. Then plain equality (`:2153`, `:2159`). Lineage not yet wired.

**The MCP server must NEVER hold both an implementer and a reviewer key in one process** — the 409s are
correct behavior; do not add a workaround.

## Capability tokens (L1) — signed, scoped, single-use

`lib/loopctl/capabilities.ex`:
- `mint/4` (`:30-57`) — per-`(typ, story_id, lineage)` token (`start_cap` / `report_cap` / `verify_cap` /
  `review_complete_cap`), signed, nonce'd, bounded TTL.
- `verify/2` (`:64-84`) — type match + story match + **lineage exact match** + not-expired + not-consumed
  + nonce exists.
- `consume/1` (`:91-104`) — **atomic** `update_all ... where consumed_at IS NULL`; the `{0, _}` branch
  returns `:replay`. This is the TOCTOU-safe single-use guard — never replace it with a read-then-write.

## Dispatch lineage (L4) — structural verifier separation

`lib/loopctl/dispatches.ex`: each dispatch carries a `lineage_path` (root → self);
`lineage_shares_prefix?/2` (`:269-273`) is the primitive the self-verify check uses; `select_verifier/3`
(`:288`) picks a verifier off the implementer's lineage. Ephemeral per-dispatch keys (minted via
`POST /api/v1/dispatches`, MCP `dispatch` tool) replace long-lived env-var keys.

## Anti-patterns

- Lowering a role on a destructive/custody endpoint "for convenience" — re-check the CLAUDE.md checklist.
- "Fixing" a `self_*_blocked` 409 by sharing keys or collapsing lineage — that defeats the product.
- A capability `consume` that isn't the atomic conditional update — reintroduces replay.
- New table in the audit/custody path without the hash-chain / DB CHECK backstops (`audit_chain/`).
- Trusting a `nil` identity as permissive where the code blocks it — `verify` (`:1613`) and `report`
  (`:2107`) fail closed on nil. `review-complete` is the documented exception (`:2146-2147`, nil = human
  operator); do not "fix" it into a block without reading that comment.

## Related

- **`tenancy-rls`** — custody writes/consume run on `AdminRepo`; every custody row is tenant-scoped.
- **`knowledge-wiki`** — the KB-content carve-out (#331) is the one agent-role exception to archive/delete⇒:user.
- Security review of a custody change: dispatch the global `security-adversary` agent.
