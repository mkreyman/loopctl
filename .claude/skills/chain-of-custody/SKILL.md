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

Ranks and `role_at_least?/2` live in `lib/loopctl/auth/role.ex:7-30`; enforcement is the
`LoopctlWeb.Plugs.RequireRole` plug (`lib/loopctl_web/plugs/require_role.ex`). Higher roles inherit
lower-role endpoints. Human-rooted operations additionally pass `RequireHumanAnchor`
(`lib/loopctl_web/plugs/require_human_anchor.ex`, WebAuthn L0).

**Where the line sits (CLAUDE.md "Security & Trust Model" checklist — the authority):**
- `role: :user` (or WebAuthn): anything IRREVERSIBLE or that is itself a custody gate — tenant/project
  delete, budget/token corrections, cost-anomaly resolution, audit-key rotation, break-glass, and the
  irreversible **HARD** bulk KB delete.
- `role: :orchestrator`: constructive/metadata work-breakdown (create/update epics, stories, deps,
  imports, backfills) so an autonomous orchestrator composes projects without a human.
- `role: :agent`: read work-breakdown only; **KB-content curation is the carve-out** — create/update/
  soft-archive/resolve-conflict are agent-role because each is reversible + audited (see `knowledge-wiki`).

Rule of thumb before lowering any role: *does this let one session both implement AND verify/report?*
If yes, the change is wrong.

## The self-* gates — the 409s are the system working

Enforced in `lib/loopctl/progress.ex`, **lineage-first** (dispatch model), agent-id equality only as the
pre-dispatch fallback:
- **verify** — `validate_not_self_verify/2` `progress.ex:1613-1648`. Compares implementer vs verifier
  **dispatch lineage** via `Dispatches.lineage_shares_prefix?/2`; a shared prefix ⇒ `:self_verify_blocked`.
  A `nil` orchestrator identity is untrusted (`:1613`); a custody-orphaned story fails closed
  (`:1626-1628`, "nil is never permissive").
- **report** — `validate_not_self_report/2` `progress.ex:2107-2123`.
- **review-complete** — `:self_review_blocked` `progress.ex:2154`.

CLAUDE.md still phrases these as "409 if caller == assigned_agent_id" — that's the fallback branch
(`progress.ex:1642`); the primary check is lineage-prefix, not id equality. **The MCP server must NEVER
hold both an implementer and a reviewer key in one process** — the 409s are correct behavior; do not add
a workaround.

## Capability tokens (L1) — signed, scoped, single-use

`lib/loopctl/capabilities.ex`:
- `mint/4` (`:17-42`) — per-`(typ, story_id, lineage)` token (`start_cap` / `report_cap` / `verify_cap` /
  `review_complete_cap`), signed, nonce'd, bounded TTL.
- `verify/2` (`:52-69`) — type match + story match + **lineage exact match** + not-expired + not-consumed
  + nonce exists.
- `consume/1` (`:76-89`) — **atomic** `update_all ... where consumed_at IS NULL`; the `{0, _}` branch
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
- Trusting a `nil` identity as permissive anywhere in custody — every gate fails closed on nil.

## Related

- **`tenancy-rls`** — custody writes/consume run on `AdminRepo`; every custody row is tenant-scoped.
- **`knowledge-wiki`** — the KB-content carve-out (#331) is the one agent-role exception to archive/delete⇒:user.
- Security review of a custody change: dispatch the global `security-adversary` agent.
