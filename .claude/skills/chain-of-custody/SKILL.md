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
(`Dispatches.lineage_for_api_key/2`, `dispatches.ex:526-536`) — never read from the request body.

- **verify** — `validate_not_self_verify/4`. `nil` orchestrator identity is untrusted; a custody-orphaned story fails closed with
  `:missing_assigned_agent` ("nil is never permissive"); then the CALLER's lineage vs the
  implementer's (`lineage_status/2`) — the SAME gate report and review-complete use, at the SAME
  `lineage_same_chain?/2` distance (ancestor/descendant blocked, SIBLING allowed), arriving as
  `:verifier_lineage` and resolved server-side, which is the only clause that binds the principal
  actually calling. It is passed on every path that reaches `verified`/`rejected` (`verify`,
  `verify-all`, `reject`, bulk verify/reject via `ensure_verify_allowed/4`); the private guard takes
  it with no default, and the public opts boundary still defaults it to `[]` — which no longer
  DEGRADES, because on dispatch-minted work `[]` is `:unlineaged`. An EMPTY caller lineage on a
  story that HAS an `implementer_dispatch_id` is refused with `:caller_lineage_required` — a key no
  dispatch minted cannot be shown separate from dispatch-minted work. Its own code, not
  `self_verify_blocked`: the latter is an L6 byzantine signal that escalates to a tenant-wide halt,
  and an unmigrated legacy key would have armed it on every call. REJECT is exempt from that one
  refusal (`unlineaged_caller/3`) — sending work back is the remediation path, and refusing it
  strands the story at reported_done. THEN the RECORDED verifier
  (`verify_recorded_separation/2`) when BOTH `implementer_dispatch_id` and
  `verifier_dispatch_id` are set, decided by `verify_lineage_separated/4`.
  An EMPTY lineage on either side (what an unloadable dispatch yields,
  `get_dispatch_lineage/2`) fails **CLOSED**, and the `assigned_agent_id`
  equality check runs IN ADDITION to the lineage comparison rather than being short-circuited by it.
  `verifier_dispatch_id` is written only by the assign-verifier flow (`assign_rotating_verifier/3`,
  `progress.ex:520-559`); that write is result-checked, and a failure flags `verifier_needed` plus a
  `verifier_not_assigned` audit event (`flag_verifier_needed/5`, `progress.ex:572`) instead of
  silently leaving the field nil. `request-review` is OPTIONAL, so most stories reach verify with no
  verifier dispatch — the CALLER-lineage step is what keeps that path lineage-gated.
- **report** — `validate_not_self_report/3`. `nil` caller blocked
  ; a story with nil `assigned_agent_id` AND nil `implementer_dispatch_id` is
  **custody-unattributed** and fails closed with `:missing_assigned_agent` + a
  `custody_orphaned_blocked` log (`custody_unattributed?/1`) — it used to
  pass vacuously; then the reporter's lineage vs the implementer's (`lineage_status/2`) —
  `:ok | :conflict | :unresolvable | :unlineaged`, where an unresolvable implementer dispatch fails
  CLOSED with `unresolvable_dispatch_lineage` (LCP-1 §7.5) and is ranked BEFORE `:unlineaged` so an
  empty caller lineage cannot mask a broken dispatch reference; then plain `assigned_agent_id`
  equality.
- **review-complete** — `validate_not_self_review/3`. Custody-orphan backstop first, then a **`nil`
  reviewer WITH AN EMPTY LINEAGE is deliberately PERMITTED** because that pair means a human
  operator on a user-role key — the empty-lineage half is load-bearing, since a DISPATCH-minted
  user-role key also has no `agent_id` and permitting on nil alone let an ANCESTOR of the
  implementer review its own subtree; then the reviewer's lineage; then plain equality. That nil
  permit has THREE parts, all of which must change
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

**Backfill is the fourth way to reach `verified`, and its guard is `stories.lifecycle_entered_at`.**
`backfill_story/4` / `ensure_mark_complete_allowed/2` certify with no report, no review record and no
verifier, so they are confined to work that never entered the lifecycle. State alone cannot answer
that: `force_unclaim_story/3` CLEARS `assigned_agent_id`, and a legacy bearer claim never writes
`implementer_dispatch_id`, so claim -> force-unclaim leaves a worked story indistinguishable from
pre-loopctl work. `guard_no_lifecycle_history/2` (`progress.ex`) consults three sources: the
`lifecycle_entered_at` COLUMN, a legacy `metadata["lifecycle_entered_at"]` key, and the `audit_log`
(retention-bounded — `AuditPartitionWorker` DROPs partitions past `:audit_retention_days`, so it
expires). The column is stamped by all FOUR paths that clear `assigned_agent_id` on a worked story
(`unclaim_story/3`, `force_unclaim_story/3`, `perform_auto_reset/4` and
`BulkOperations.auto_reset_agent_status/1`) and never cleared. Re-running `force_unclaim_story/3` on
a story already at `:pending` stamps it too — the remedy for a story reset before the column
existed — but only when the row or the audit log still shows it was worked. **It is a
column and not a `metadata` key on purpose**: `metadata` is cast by `Story.update_changeset/2` and
REPLACED wholesale by `PATCH /api/v1/stories/:id`, so one ordinary orchestrator request erased the
marker and handed the launder path back. Never add `:lifecycle_entered_at` to a `cast` list.

**The MCP server must NEVER hold both an implementer and a reviewer key in one process** — the 409s are
correct behavior; do not add a workaround.

## Capability tokens (L1) — signed, scoped, single-use

`lib/loopctl/capabilities.ex`:
- `mint/4` (`capabilities.ex:33-58`) — per-`(typ, story_id, lineage)` token, signed, nonce'd,
  bounded TTL. **Only `start_cap` is minted (#621).** `report_cap` and `verify_cap` were retired
  because a capability cannot gate a transition whose whole point is that a DIFFERENT principal
  performs it: the token binds to one lineage exactly, and that lineage is either the principal
  forbidden to spend it (report) or one that cannot reach the endpoint (verify — the verifier
  pool includes `:agent` dispatches, the endpoint is `exact_role: :orchestrator`, and a legacy
  env-var key has lineage `[]`). Those transitions are gated by L4 instead. Do not "restore"
  them without first making the entitled principal able to obtain the token.
- `verify/2` (`capabilities.ex:71-90`), decided by `validate_cap/6` (`capabilities.ex:186-196`) —
  type match + story match + **lineage exact match** + not-expired + not-consumed + a valid
  **ed25519 signature** over the token fields, checked against the tenant's
  `audit_signing_public_key` (`verify_signature/2`, `capabilities.ex:198-225`, which returns false —
  fails CLOSED — when the tenant has no pubkey). There is NO "nonce exists" check; the nonce is an
  input to the signed message. The signature is the ONLY cryptographic check — never remove it as
  ceremony.
- `consume/1` (`capabilities.ex:97-110`) — **atomic** `update_all ... where consumed_at IS NULL`; the
  `{0, _}` branch returns `:replay`. This is the TOCTOU-safe single-use guard — never replace it with
  a read-then-write.

**Enforcement is conditional — this is the deprecation seam.** `Progress.maybe_consume_cap/6`
(`progress.ex:352-398`) is what actually gates the custody ops: a `nil` `cap_id` is rejected with
`:missing_capability` **only for tenants that have an audit key** (`tenant_has_audit_key?/1`,
`progress.ex:600-605`); a pre-v2 (keyless) tenant returns `{:ok, :pre_v2_tenant}` and the operation
proceeds with NO capability at all. So L1 strength is per-tenant. A REJECTED cap is split by
`cap_refusal/4`: only `:invalid_signature` / `:replay` surface as `{:cap_rejected, _}`, which
FallbackController answers with a plain 403 — it halts NOTHING and counts toward nothing (see the
L6 section). `:expired` and `:wrong_lineage` are ordinary client errors (a slow agent, a rotated
dispatch) and degrade to `:missing_capability` — never let a timeout 503 a whole tenant. That branch now emits a
`pre_v2_custody_bypass` warning plus a `[:loopctl, :custody, :pre_v2_bypass]` telemetry event, so the
degraded tenants are observable — alert on the count. Do not "simplify" the clause: removing the
audit-key condition either breaks pre-v2 tenants or silently widens the bypass.

## Dispatch lineage (L4) — structural verifier separation

`lib/loopctl/dispatches.ex`: each dispatch carries a `lineage_path` (root → self).
Two primitives serve the self-* checks and they demand DIFFERENT distance — see "The two lineage
comparisons" below before touching either. `lineage_shares_prefix?/2` is the stricter one, and it
applies where separation is guaranteed BY CONSTRUCTION (verifier SELECTION, and the RECORDED
verifier) rather than demanded of an arbitrary caller: it compares lineage **ROOTS** (element 0)
only, not arbitrary prefixes, and an empty list on either side is never a match. Every CALLER
comparison — report, review-complete and verify alike — uses `lineage_same_chain?/2`.
`select_verifier/3` picks a verifier whose lineage does
NOT share the implementer's root — rejected in SQL (`reject_same_root/2`) and again in Elixir — from
a pool capped at `@verifier_pool_limit`.

**The selection index must come from a SECRET the candidates do not hold.** The pool is
enumerable by any agent key (`GET /api/v1/dispatches`) and the story id is known, so the seed
is the only thing standing between "deterministic" and "predictable". `verifier_seed/2`
keys an HMAC with the tenant's audit signing **private** key (`TenantKeys`, secret store + ETS),
domain-separated and bound to `(tenant, story)`. It used to hash the **public** key, which is
served unauthenticated on the discovery endpoint — every candidate could precompute its own
selection. No public value is an acceptable fallback, so the no-secret case (pre-v2 tenant,
unreachable secret store) returns `{:error, :verifier_seed_unavailable}` and the story is flagged
`verifier_needed` instead: selecting nobody is strictly better than selecting predictably, because
verify enforces lineage separation either way — it compares the CALLER's lineage on every path and
refuses an unlineaged caller on a dispatch-minted story rather than falling back to agent-id
inequality. That failure also emits
`[:loopctl, :custody, :verifier_seed_unavailable]`; a secret-store outage fires it on every
request-review deployment-wide, so alert on the counter rather than reading logs.

An empty pool has TWO causes with different remedies and they are reported separately:
`:no_eligible_verifier` (no active dispatch at all) versus `:no_independent_root` (dispatches
exist, but every one descends from the implementer's root — the single-root tenant). The second is
not a shortage; its remedy is the operator minting an independently-rooted verifier tree.

**Empty-lineage caveat, in BOTH directions.** When the implementer dispatch cannot be loaded,
`assign_rotating_verifier/3` passes `[]` (`progress.ex:520-524`), and with `[]` the rejection is
inert — selection can then pick a same-lineage (even the implementer's own) dispatch. The verify-time
comparison is fail-closed on an empty lineage, so this is caught at verify rather than at selection;
do not "simplify" either half.

Ephemeral per-dispatch keys (minted via `POST /api/v1/dispatches`, MCP `dispatch` tool) replace
long-lived env-var keys.

**The lineage CEILING on minting — you may only dispatch inside your own subtree.**
`LoopctlWeb.DispatchController.create/2` (`lib/loopctl_web/controllers/dispatch_controller.ex:20-59`)
resolves the CALLER's lineage server-side and refuses two shapes:

- a **parentless** create by anyone but the OPERATOR → `403 root_dispatch_forbidden`.
  A root dispatch starts a NEW tree sharing no root with anything, which the L4 checks read as an
  unrelated principal; a caller able to mint one can hand itself separation from its own work.
- a parent **outside** the caller's lineage → `403 parent_outside_caller_lineage`
  (`lineage_within_caller?/3`). Closing only the parentless case would leave the same escape one
  step out, since every dispatch id in the tenant is enumerable. A caller with NO lineage of its
  own is exempt from this half: it has no subtree to step outside of, and refusing it here closed
  the only mint a legacy `:orchestrator` key had left — leaving it unable to obtain a lineage by
  ANY request, and therefore unable to verify anything, against the documented deprecation window.
  Naming a parent gives it a lineage, which SUBJECTS it to the custody gates.

**"Operator" is a POSITIVE test, not an absent lineage**: `lineage_for_api_key/2` returns `[]` for
three different principals — the tenant's human-anchored operator key (`role: :user`, minted by the
signup ceremony), a legacy long-lived env-var key, and a key whose dispatch row no longer resolves.
Only the first deserves the privilege, so the check is `caller_lineage == [] and
Role.role_at_least?(role, :user)`. Inferring it from `[]` alone let every legacy `:orchestrator`
key hand itself an independently-rooted dispatch for the whole deprecation window.

**The ceiling covers CREDENTIAL MINTING, not just dispatch minting.** A plain API key was
minted by no dispatch, so `lineage_for_api_key/2` resolves it to `[]` — the same shape the
root half admits. A dispatch-minted `:user`-role key could therefore mint (or rotate itself)
a plain key at `POST /api/v1/api_keys` and, holding it, start the independent tree it had
just been refused. `LoopctlWeb.Plugs.RequireUnlineagedCaller`
(`lib/loopctl_web/plugs/require_unlineaged_caller.ex`) closes that: `create` and `rotate` —
the two actions that hand back a raw key — are refused with `403 api_key_mint_forbidden`
when the caller carries a lineage. The invariant is **credentials that carry no lineage may
only be minted by a principal that has none**; the key is NOT made to inherit the minter's
lineage, because a key's lineage IS its `dispatches` row, and a second lineage source that
the custody gates did not read would be the same failure one layer down. Reads (`index`) and
`delete` are unaffected.

All three refusals are logged (`lineage_ceiling_refused`) and emit
`[:loopctl, :custody, :lineage_ceiling_refused]`. A 403 body carries the caller's own
`your_dispatch_id` when it HAS one — the remediation says "mint under your own dispatch", and
nothing else on this API tells a caller which row is its own. For a caller with no lineage the key
is OMITTED (never a bare null) and the message names a remedy that caller can actually perform:
pass any active dispatch as `parent_dispatch_id`, or have the operator key mint the root. **A
refusal that names an action the refused caller cannot take is a dead end, not a remediation** —
that is the recurring defect on this surface; check every new 403 message against it.

This is the structural analogue of the role ceiling (`role_exceeds_caller?/2`) directly above it.
It does mean a tenant is single-rooted unless the OPERATOR mints a second tree. That is a
selection-quality concern, NOT a liveness one: `select_verifier/3` still wants a different-root
candidate and reports `:no_independent_root` (distinct from an empty pool) when it has none, but
the verify GATE is chain-separated, so a sibling verifier under the same root certifies fine. Do
not "fix" selection by relaxing the ceiling; mint a second root from the operator key.

## Custody halt (L6) — escalation is thresholded, and the halt is SCOPED

A halt freezes the tenant's custody surface and only a human WebAuthn break-glass ceremony
clears it, so both its trigger and its blast radius are deliberately bounded.

- **Trigger** — `Loopctl.Custody.ViolationMonitor.record/3` (`lib/loopctl/custody/violation_monitor.ex`),
  called from the `FallbackController`'s `:self_verify_blocked` / `:self_report_blocked` /
  `:self_review_blocked` clauses — all three lineage-aware gates count.
  It records the violation in `custody_violations` (tenant-scoped, RLS) and halts only when
  `threshold/0` violations land inside `window_seconds/0` (defaults 3 / 3600, each rejected back
  to its default unless a positive integer). **Below the
  threshold the custody gate still returns its 409** — only the escalation is thresholded.
  A halt CLAIMS the rows that armed it (`consumed_at`) **in the same transaction as the halt**, so
  concurrent callers cannot produce two onsets and a FAILED halt rolls the claim back instead of
  pardoning the window it was armed by. Violations recorded while a halt is already active are
  claimed on sight, so the break-glass clear is never re-tripped by evidence that piled up behind
  the halt.
- **`cap_rejected` NEVER halts and NEVER counts.** A capability is single-use with a bounded
  TTL, so a client retry (`:replay`), a resumed agent (`:expired`) and an audit-key rotation
  (`:invalid_signature`) all produce one; none is a byzantine signal, and the 403 already
  refuses the operation. It emits `[:loopctl, :custody, :cap_rejected]` telemetry instead —
  alert on the RATE. Do not re-add a halt there. **Not halting is not the same as not
  recording**: EVERY cap refusal is hash-chained by `record_cap_refusal/4`, and the append is
  piped through `AuditChain.log_append_failure/4` so a lost entry is loud — `:invalid_signature`
  as `capability_forged` (the only one carrying `byzantine: true` — the flag is derived from
  the ACTION, since a retry produces a replay and neither the name nor the flag may call that
  a forgery), `:replay` as `capability_replayed`, the rest as `capability_refused`. That used
  to run the wrong way round, with `:wrong_lineage` chained and a FORGED signature left with
  only a log line; since the refusal no longer halts, the audit entry IS its durable record.
- **Scope** — `LoopctlWeb.CustodySurface` (`lib/loopctl_web/custody_surface.ex`) is THE list of
  operations a halt suspends: story-lifecycle writes, bulk story ops + `verify-all`, project
  import (`initial_agent_status` records work as done), dispatch minting, agent-memory writes
  (recall included — it bumps the graduation hotness counters), and DELETE of a
  story/epic/project (that row IS the custody evidence). **Reads are never blocked** —
  `custody_operation?/1` short-circuits on GET/HEAD/OPTIONS. `CheckCustodyHalt` consults it;
  `test/loopctl_web/custody_surface_test.exs` binds the declared list to
  `LoopctlWeb.Router.__routes__/0` and fails when a mutating custody route is unclassified.
  Add the route's shape to `CustodySurface`; never relax that test.
- Root-of-trust rotation and the superadmin break-glass stay reachable during a halt — they are
  the remediation paths. A standalone superadmin key has a nil `tenant_id`, so the halt check
  never applies to it.
## The two lineage comparisons — CALLERS and SELECTION demand DIFFERENT distance

There are two, and using the wrong one either breaks the product or weakens the gate:

- `Dispatches.lineage_same_chain?/2` — ancestry: identical, or one an ancestor of the other.
  A SIBLING passes. Used by every CALLER comparison — **report**, **review-complete** AND
  **verify** (`lineage_status/2`).
- `Dispatches.lineage_shares_prefix?/2` — shared ROOT (element 0 only). A sibling is BLOCKED.
  Used where separation is guaranteed by CONSTRUCTION rather than demanded of whoever calls:
  `select_verifier/3`'s `reject_same_root/2`, and `verify_lineage_separated/4` on the RECORDED
  verifier that selection produced.

Why they differ: the documented dispatch tree puts the implementer and the reviewer side by
side under one orchestrator, and roots the whole tenant at one operator dispatch. Under a
root test *every* pair of dispatches in a tenant matches, so the reviewer counts as the
implementer and nothing can ever be reported — and applying it to verify's CALLER left a
single-root tenant with no principal able to certify anything at all, which is why verify's
caller comparison is `:chain` too. This was invisible until #621 began recording
`implementer_dispatch_id` on the HTTP path, which is what made the comparison run at all.
The selector keeps the root test: it CHOOSES the candidate, so it can insist on the stronger
property without stranding anyone.

Neither relaxes self-approval — `assigned_agent_id` equality is evaluated IN ADDITION at every
gate, and an empty lineage is never a match.

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
- Trusting a `nil` identity as permissive where the code blocks it — `verify` and `report` fail
  closed on nil *caller identity*. The one documented exception is `review-complete` (nil agent
  AND empty lineage = human operator, paired with the exact_role plug and the controller check).
  Do not "fix" it without reading its comment, and do not drop the lineage half.
- Answering an ordinary configuration refusal with an L6 code. `self_*_blocked` records a custody
  violation and escalates to a tenant-wide halt; "your key has no dispatch lineage" is a setup
  state that fires on every call, so it is `caller_lineage_required` (plain 409).

## Related

- **`tenancy-rls`** — custody writes/consume run on `AdminRepo` (BYPASSRLS: an explicit `tenant_id`
  predicate is the ONLY isolation). Custody READS fetch by `(id, tenant_id)`; `Capabilities.consume/1`
  (`capabilities.ex:97-110`) is **id-only** — its `update_all` filters on `c.id` alone (`:97-98`) and
  inherits its tenant scoping from the `verify/2` that fetched the row. Never call it on a row you did
  not fetch tenant-scoped.
- **`knowledge-wiki`** — the KB-content carve-out (#331) is the one agent-role exception to archive/delete⇒:user.
- Security review of a custody change: dispatch the global `security-adversary` agent.
