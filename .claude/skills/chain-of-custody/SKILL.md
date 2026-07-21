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
`LoopctlWeb.Plugs.RequireRole` plug (`lib/loopctl_web/plugs/require_role.ex`).

**Hierarchy inheritance applies ONLY to `role:` gates.** The plug has a second mode,
`exact_role:` (a single atom or a list), which does NO hierarchy — a HIGHER role is 403'd like
any other non-member (`require_role.ex:37-70`). Every chain-of-custody endpoint is exact-role
gated, so escalating to a bigger key never clears a 403 there:

| Endpoint | Gate |
|----------|------|
| `verify` / `reject` / `force_unclaim` / `verify_all` | `exact_role: :orchestrator` (`story_verification_controller.ex:28-29`) — a superadmin key CANNOT verify |
| `contract` / `report` | `exact_role: [:agent, :orchestrator]` (`story_status_controller.ex:26-30`) — a human user key CANNOT report |
| `claim` / `start` / `request-review` / `unclaim` | `exact_role: :agent` (`story_status_controller.ex:32-33`) |
| `review-complete` | `exact_role: [:orchestrator, :user]` (`review_record_controller.ex:22-23`) — an agent key never reaches the controller |

**Anti-pattern: never "normalize" an `exact_role` custody gate to `role:`.** That is exactly what
would let one high-privilege key both implement and report/verify.

Human-rooted operations additionally pass `RequireHumanAnchor`
(`lib/loopctl_web/plugs/require_human_anchor.ex`), which gates on the TENANT's `trust_tier` and is
**deliberately orthogonal to role** (`:4`, `:9`). Three branches, in order:
1. `current_tenant: nil` — a superadmin key that is NOT impersonating — passes **unconditionally**, no
   tier evaluated (`:44-49`). `Impersonate` reassigns `current_tenant` before controller plugs run, so an
   impersonated agent-rooted tenant IS still gated.
2. `trust_tier: :human_anchored` passes (`:51`).
3. Everything else — a catch-all, which covers `:agent_rooted` AND a missing `current_tenant` assign —
   halts with `403 custody_tier_required` (`:55`, `:61`).

It is not a per-request WebAuthn check — WebAuthn is how a tenant EARNS `:human_anchored`. Keying on
tier rather than role is what closes the self-minted-key bypass. **The plug is in NO router pipeline —
it is opt-in per controller** (e.g. `story_verification_controller.ex:35`, `dispatch_controller.ex:16`,
`artifact_report_controller.ex:30`), so a new human-rooted endpoint gets NO trust-tier gate unless you
add the plug line yourself.

**Where the line sits (CLAUDE.md "Security & Trust Model" checklist — the authority):**
- `role: :user` (or WebAuthn): anything IRREVERSIBLE or that is itself a custody gate — tenant/`:work`-project
  delete, budget/token corrections, cost-anomaly resolution, audit-key rotation, break-glass. On the KB
  surface the `:user` set is single-article `unpublish` plus ALL the set-based bulk ops — `bulk_publish`,
  `bulk_unpublish` and the ENTIRE `bulk_delete` action, soft path included
  (`article_workflow_controller.ex:37-39`). **Two criteria hold that line: set-based blast radius (one
  call mutates an unbounded set) AND irreversibility (`bulk_delete` carries a hard-delete path).**
  Neither criterion alone is the rule — do not drop reversibility when reasoning about a new op.
- `role: :orchestrator`: constructive/metadata work-breakdown (create/update epics, stories, deps,
  imports, backfills) so an autonomous orchestrator composes projects without a human. Also KB
  `drafts` / single-article `publish` (`article_workflow_controller.ex:33`).
- `role: :agent`: read work-breakdown only; **KB-content curation is the carve-out** — create/update/
  soft-archive/resolve-conflict are agent-role because each is reversible + audited (see `knowledge-wiki`).
- `role: :agent`, **human-anchor-EXEMPT**: `:kb`-kind project scopes — `create_kb_scope`,
  `archive_kb_scope`, `restore_kb_scope` (`project_controller.ex:25-35`), deliberately outside
  `RequireHumanAnchor` (`project_controller.ex:37-41`) because a `:kb` scope carries no chain-of-custody surface
  (`RequireWorkProject` bars work attachment). Extends owner decision #331. An existing agent-role
  kb-scope archive is NOT a custody violation. `:work` projects stay `:orchestrator`/`:user` + anchored.

Rule of thumb before lowering any role: *does this let one session both implement AND verify/report?*
If yes, the change is wrong.

## The self-* gates — the 409s are the system working

Enforced in `lib/loopctl/progress.ex`. The three gates are NOT one implementation, but ALL THREE now
compare dispatch lineage and all three fail closed on a story with no custody provenance. The
caller's lineage is always resolved SERVER-SIDE from the authenticating key
(`Dispatches.lineage_for_api_key/2`, `dispatches.ex:282-292`) — never read from the request body.

- **verify** — `validate_not_self_verify/2` `progress.ex:1684-1715`. `nil` orchestrator identity is
  untrusted (`progress.ex:1682`); a custody-orphaned story fails closed with
  `:missing_assigned_agent` (`progress.ex:1697-1699`, "nil is never permissive"); the lineage clause
  runs when BOTH `implementer_dispatch_id` and `verifier_dispatch_id` are set
  (`progress.ex:1702-1706`), decided by `verify_lineage_separated/4` (`progress.ex:1725-1745`).
  An EMPTY lineage on either side (what an unloadable dispatch yields,
  `get_dispatch_lineage/2` `progress.ex:1747-1752`) fails **CLOSED**, and the `assigned_agent_id`
  equality check runs IN ADDITION to the lineage comparison rather than being short-circuited by it.
  `verifier_dispatch_id` is written only by the assign-verifier flow (`assign_rotating_verifier/3`,
  `progress.ex:363-397`); that write is result-checked, and a failure flags `verifier_needed` plus a
  `verifier_not_assigned` audit event (`flag_verifier_needed/5`, `progress.ex:399-423`) instead of
  silently leaving the field nil. With no verifier dispatch the gate is agent-id equality.
- **report** — `validate_not_self_report/3` `progress.ex:2210-2235`. `nil` caller blocked
  (`progress.ex:2207`); a story with nil `assigned_agent_id` AND nil `implementer_dispatch_id` is
  **custody-unattributed** and fails closed with `:missing_assigned_agent` + a
  `custody_orphaned_blocked` log (`custody_unattributed?/1`, `progress.ex:2240-2243`) — it used to
  pass vacuously; then the reporter's lineage vs the implementer's (`lineage_conflict?/2`,
  `progress.ex:2249-2256`); then plain `assigned_agent_id` equality.
- **review-complete** — `validate_not_self_review/3` `progress.ex:2258-2288`. Custody-orphan backstop
  first (`progress.ex:2265-2267`), then a **`nil` reviewer is deliberately PERMITTED**
  (`progress.ex:2274-2275`) because nil means a human operator on a user-role key; then the
  reviewer's lineage; then plain equality. That nil permit has THREE parts, all of which must change
  together: (a) the `exact_role: [:orchestrator, :user]` plug (`review_record_controller.ex:22-23`),
  which 403s an agent key before the controller runs — so the `:agent` branch of the controller cond
  is unreachable today; (b) `LoopctlWeb.ReviewRecordController.create/2`
  (`lib/loopctl_web/controllers/review_record_controller.ex:92-116`), which rejects an orchestrator
  key with no `agent_id` and passes a literal `nil` (there is NO sentinel) for a user key; (c) the
  `Progress` permit itself.

**Custody-orphan predicates are the ONLY guard for the never-dispatched case.** The DB CHECK
`stories_reported_done_requires_agent` is satisfied whenever `implementer_dispatch_id IS NULL`, which
is exactly the orphaned shape — do not delete `custody_orphaned?/1` or `custody_unattributed?/1` as
redundant with the constraint.

**The MCP server must NEVER hold both an implementer and a reviewer key in one process** — the 409s are
correct behavior; do not add a workaround.

## Capability tokens (L1) — signed, scoped, single-use

`lib/loopctl/capabilities.ex`:
- `mint/4` (`capabilities.ex:32-57`) — per-`(typ, story_id, lineage)` token (`start_cap` /
  `report_cap` / `verify_cap` / `review_complete_cap`), signed, nonce'd, bounded TTL.
- `verify/2` (`capabilities.ex:67-84`), decided by `validate_cap/6` (`capabilities.ex:125-135`) —
  type match + story match + **lineage exact match** + not-expired + not-consumed + a valid
  **ed25519 signature** over the token fields, checked against the tenant's
  `audit_signing_public_key` (`verify_signature/2`, `capabilities.ex:137-164`, which returns false —
  fails CLOSED — when the tenant has no pubkey). There is NO "nonce exists" check; the nonce is an
  input to the signed message. The signature is the ONLY cryptographic check — never remove it as
  ceremony.
- `consume/1` (`capabilities.ex:91-104`) — **atomic** `update_all ... where consumed_at IS NULL`; the
  `{0, _}` branch returns `:replay`. This is the TOCTOU-safe single-use guard — never replace it with
  a read-then-write.

**Enforcement is conditional — this is the deprecation seam.** `Progress.maybe_consume_cap/6`
(`progress.ex:323-346`) is what actually gates the custody ops: a `nil` `cap_id` is rejected with
`:missing_capability` **only for tenants that have an audit key** (`tenant_has_audit_key?/1`,
`progress.ex:425-431`); a pre-v2 (keyless) tenant returns `{:ok, :pre_v2_tenant}` and the operation
proceeds with NO capability at all. So L1 strength is per-tenant. That branch now emits a
`pre_v2_custody_bypass` warning plus a `[:loopctl, :custody, :pre_v2_bypass]` telemetry event, so the
degraded tenants are observable — alert on the count. Do not "simplify" the clause: removing the
audit-key condition either breaks pre-v2 tenants or silently widens the bypass.

## Dispatch lineage (L4) — structural verifier separation

`lib/loopctl/dispatches.ex`: each dispatch carries a `lineage_path` (root → self).
`lineage_shares_prefix?/2` (`dispatches.ex:303-307`) is the primitive the self-* checks use — note it
compares lineage **ROOTS** (element 0) only, not arbitrary prefixes, and an empty list on either side
is never a match. `select_verifier/3` (`dispatches.ex:329-364`) picks a verifier whose lineage does
NOT share the implementer's root — rejected in SQL (`reject_same_root/2`, `dispatches.ex:374-380`)
and again in Elixir — from a pool capped at `@verifier_pool_limit`, seeded deterministically by
`sha256(tenant audit pubkey || story_id)` so the orchestrator cannot predict the pick.

**Empty-lineage caveat, in BOTH directions.** When the implementer dispatch cannot be loaded,
`assign_rotating_verifier/3` passes `[]` (`progress.ex:363-367`), and with `[]` the rejection is
inert — selection can then pick a same-lineage (even the implementer's own) dispatch. The verify-time
comparison is fail-closed on an empty lineage, so this is caught at verify rather than at selection;
do not "simplify" either half.

Ephemeral per-dispatch keys (minted via `POST /api/v1/dispatches`, MCP `dispatch` tool) replace
long-lived env-var keys.

## Anti-patterns

- Lowering a role on a destructive/custody endpoint "for convenience" — re-check the CLAUDE.md checklist.
- "Fixing" a `self_*_blocked` 409 by sharing keys or collapsing lineage — that defeats the product.
- A capability `consume` that isn't the atomic conditional update — reintroduces replay.
- New table in the audit/custody path without the hash-chain / DB CHECK backstops (`audit_chain/`).
- Adding a new human-rooted endpoint WITHOUT an explicit `plug RequireHumanAnchor` line — the plug is
  per-controller opt-in, not pipeline-wide, so the gate is silently absent.
- Using a dispatched sub-agent to report or review-complete its PARENT's work — all three gates now
  compare lineage, so this is blocked; do not "route around" it by minting a key outside the lineage.
- Taking the caller's lineage from request params instead of `Dispatches.lineage_for_api_key/2` —
  a client-supplied lineage is self-attested and defeats the gate.
- Trusting a `nil` identity as permissive where the code blocks it — `verify`
  (`progress.ex:1682`) and `report` (`progress.ex:2207`) fail closed on nil *caller identity*. The one
  documented exception is `review-complete` (`progress.ex:2274-2275`, nil = human operator, paired
  with the exact_role plug and the controller check). Do not "fix" it without reading its comment.

## Related

- **`tenancy-rls`** — custody writes/consume run on `AdminRepo` (BYPASSRLS: an explicit `tenant_id`
  predicate is the ONLY isolation). Custody READS fetch by `(id, tenant_id)`; `Capabilities.consume/1`
  (`capabilities.ex:91-104`) is **id-only** — its `update_all` filters on `c.id` alone (`:97-98`) and
  inherits its tenant scoping from the `verify/2` that fetched the row. Never call it on a row you did
  not fetch tenant-scoped.
- **`knowledge-wiki`** — the KB-content carve-out (#331) is the one agent-role exception to archive/delete⇒:user.
- Security review of a custody change: dispatch the global `security-adversary` agent.
