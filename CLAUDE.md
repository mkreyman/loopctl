# loopctl

Agent-native project state store for AI development loops.
Stack: Elixir 1.18 / Phoenix 1.8, PostgreSQL with RLS, Oban, Req, Cloak.
Web: Phoenix LiveView (landing page + future admin), Tailwind CSS v4.

**Also read [AGENTS.md](AGENTS.md)** — contains Phoenix 1.8 framework guidelines, Elixir conventions, Ecto patterns.

## Design System Reference

Refer to `docs/design-system.md` for full specifications. Key points:

- **Dark mode only** — no light mode for v1
- **Color palette**: cool slate grays (`slate-*`), deep indigo-blue accent (`accent-*`)
- **Typography**: Geist (headings + body), Geist Mono (IDs, agent names, code, status badges)
- **Cards**: `rounded-md` (6px), no shadows on inline cards, border-only structure
- **Terminal aesthetic**: monospace for data, cool blue-gray tones, precision over decoration
- **Anti-patterns**: no rounded-xl, no gradients, no glassmorphism, no warm grays, no centered heroes

---

## CRITICAL: Load Orchestration State on Every Session Start

**YOU MUST** load the orchestration protocol and build status from memory-keeper at the start of every conversation:

```
mcp__memory-keeper__context_get({ key: "CRITICAL_ALWAYS_READ_FIRST_PRINCIPLES", channel: "loopctl" })
mcp__memory-keeper__context_get({ key: "build_status", channel: "loopctl" })
```

These contain:
- The orchestration loop rules (you are READ-ONLY on code, you dispatch agents)
- Current build progress (which epics/stories are done)
- Architectural decisions made during implementation
- The DI, fixture, and mock patterns to enforce

**Do NOT proceed with any implementation work until you have loaded and read both keys.**

---

## Module Structure

```
lib/loopctl/
├── tenants/           # Tenants, multi-tenancy
├── auth/              # API keys, auth pipeline, RBAC
├── audit/             # Immutable audit log
├── agents/            # Agent registry
├── projects/          # Projects CRUD
├── work_breakdown/    # Epics, stories, dependencies
├── progress/          # Two-tier status tracking
├── artifacts/         # Artifact reports, verification results
├── orchestrator/      # Orchestrator state checkpointing
├── webhooks/          # Webhook subscriptions, events, delivery
├── import_export/     # Bulk import/export
├── skills/            # Skill versioning and performance
├── quality_assurance/ # UI test runs and findings (project-level QA)
├── token_usage/       # Token consumption tracking, budgets, cost anomalies
├── knowledge/         # Knowledge Wiki: articles, embeddings, novelty gate, conflicts
├── memory/            # Agent memory (Epic 28): memories, session_memories
├── context_retriever/ # Governed structured access to live rows (Epic 30)
├── coordination/      # Channels, posts, handoffs
├── audit_chain/       # Hash-chained audit log, Signed Tree Heads
├── capabilities/      # Capability tokens (L1)
├── dispatches/        # Per-dispatch ephemeral keys, lineage paths (L4)
├── heavy_read.ex      # Guarded facade over HeavyReadRepo (heavy/vector reads)
├── schema.ex          # Base schema macro
├── admin_repo.ex      # BYPASSRLS repo (superadmin, custody writes)
├── heavy_read_repo.ex # BYPASSRLS repo on its own pool (heavy reads)
└── repo.ex            # Ecto Repo (RLS enforced)

lib/loopctl_web/
├── controllers/       # JSON API controllers
├── plugs/             # Auth pipeline plugs
├── router.ex          # API routes under /api/v1/
└── fallback_controller.ex
```

## Naming Conventions

- Context modules: `Loopctl.Tenants`, `Loopctl.Auth`, `Loopctl.Progress`, etc.
- Schema modules: `Loopctl.Tenants.Tenant`, `Loopctl.Auth.ApiKey`, etc.
- Controllers: `LoopctlWeb.TenantController`, `LoopctlWeb.StoryController`, etc.
- Oban workers: `Loopctl.Workers.WebhookDeliveryWorker`, etc.
- Behaviours: `Loopctl.HealthCheck.Behaviour`, `Loopctl.Webhooks.DeliveryBehaviour`, etc.

## Multi-Tenant Rules (RLS)

**CRITICAL: loopctl is multi-tenant. Every tenant's data is isolated via PostgreSQL RLS.**

1. **EVERY** table (except `tenants` and global tables) has `tenant_id`
2. **EVERY** context function takes `tenant_id` as the first argument
3. **EVERY** query is scoped by RLS policies (SET LOCAL per transaction)
4. `tenant_id` is **NEVER** in changeset `cast` — always set programmatically
5. **EVERY** test includes a tenant isolation test case
6. Three Repos: `Loopctl.Repo` (RLS enforced), `Loopctl.AdminRepo` (BYPASSRLS for superadmin), and `Loopctl.HeavyReadRepo` (BYPASSRLS on its own pool, for heavy analytical/vector reads — reach it via `Loopctl.HeavyRead`, never directly; US-27.11)

## Security & Trust Model — Mandatory Review Checklist

**EVERY change to loopctl must be evaluated against this checklist before merging.**

**Design spec:** the Chain of Custody v2 design lives in `docs/chain-of-custody-v2.md`.
Sections 2.1 and 9 in particular establish the human-rooted signup ceremony (WebAuthn)
and the chain-of-custody invariants that the rest of the system relies on. Consult it
before changing anything in the auth, signup, or audit pipelines.

### Role Hierarchy

`superadmin (4) > user (3) > orchestrator (2) > agent (1)`

Higher roles can access lower-role endpoints — but ONLY where the endpoint uses the plug's
`role:` option. `LoopctlWeb.Plugs.RequireRole` has TWO modes
(`lib/loopctl_web/plugs/require_role.ex`):

- `plug RequireRole, role: :orchestrator` — hierarchy applies (`Role.role_at_least?/2`); a `:user`
  or `:superadmin` key passes.
- `plug RequireRole, exact_role: :agent` (or a LIST of exact roles) — **NO hierarchy**. A higher
  role is 403'd like any other non-member.

**Every chain-of-custody endpoint is `exact_role`-gated**, so "just use a higher-privileged key"
does NOT clear a 403 there:

| Endpoint | Gate | Consequence |
|----------|------|-------------|
| `verify` / `reject` / `force_unclaim` / `verify_all` | `exact_role: :orchestrator` (`lib/loopctl_web/controllers/story_verification_controller.ex:28-29`) | a `:user` or `:superadmin` key CANNOT verify |
| `contract` / `report` | `exact_role: [:agent, :orchestrator]` (`lib/loopctl_web/controllers/story_status_controller.ex:26-30`) | a human `:user` key CANNOT report |
| `claim` / `start` / `request-review` / `unclaim` | `exact_role: :agent` (`:32-33`) | orchestrator/user keys cannot claim or start |
| `review-complete` | `exact_role: [:orchestrator, :user]` (`lib/loopctl_web/controllers/review_record_controller.ex:22-23`) | an `:agent` key is 403'd BEFORE any controller logic runs |

**Anti-pattern: never convert an `exact_role` custody gate to `role:`.** That is precisely what
lets one high-privilege key both implement and report/verify — the failure the product exists to
prevent. `exact_role` is the structural separation; the 403 is the gate working.

### Chain-of-Custody Enforcement

The API enforces that nobody marks their own work as done:
- `POST /stories/:id/report` — `409 self_report_blocked`
- `POST /stories/:id/review-complete` — `409 self_review_blocked`
- `POST /stories/:id/verify` — `409 self_verify_blocked`

All three gates are lineage-aware. They do NOT share one implementation, but each compares the
CALLER's dispatch lineage (resolved server-side from the authenticating key, never client-supplied)
against the implementer's, and each fails CLOSED on a story with no custody provenance.

**verify** — `validate_not_self_verify/2` (`lib/loopctl/progress.ex:1684-1715`, US-26.2.2),
in order:
1. **nil caller identity is blocked** — untrusted, never permissive (US-26.1.3, `progress.ex:1682`).
2. **Custody-orphaned story is blocked** with `missing_assigned_agent` — a reported-done
   story with no assigned agent and no lineage would otherwise pass VACUOUSLY, since a
   non-nil verifier never equals a nil implementer (`progress.ex:1697-1699`).
3. **Lineage comparison (primary)** when BOTH `implementer_dispatch_id` and
   `verifier_dispatch_id` are set (`progress.ex:1723-1728`), decided by
   `verify_lineage_separated/4` (`progress.ex:1747-1767`): an EMPTY lineage on either side —
   which is what an unloadable/deleted dispatch row yields (`get_dispatch_lineage/2`,
   `progress.ex:1769-1774`) — fails CLOSED, a shared lineage root
   (`Dispatches.lineage_shares_prefix?/2`, `lib/loopctl/dispatches.ex:374-378`) blocks, and the
   `assigned_agent_id` equality check is evaluated IN ADDITION to the lineage comparison, never
   short-circuited by it.
4. **`assigned_agent_id` equality** as the fallback for pre-dispatch stories
   (`progress.ex:1709-1710`) and for every story that lacks a verifier dispatch.

`verifier_dispatch_id` is written only by the assign-verifier flow
(`assign_rotating_verifier/3`, `progress.ex:363-397`); that write is checked, and a failure
flags `verifier_needed` plus a `verifier_not_assigned` audit event
(`flag_verifier_needed/5`, `progress.ex:399-423`) rather than silently leaving the field nil.
Without a verifier dispatch the check degrades to plain agent-id equality.

**report** — `validate_not_self_report/3` (`progress.ex:2210-2235`) — nil identity is blocked
(`progress.ex:2207`); a **custody-unattributed** story (nil `assigned_agent_id` AND nil
`implementer_dispatch_id`) fails CLOSED with `missing_assigned_agent` and a
`custody_orphaned_blocked` log (`custody_unattributed?/1`, `progress.ex:2268-2271`) instead of
passing vacuously; then the reporter's dispatch lineage is compared against the implementer's
(`lineage_status/2`, `progress.ex:2300-2318`) — a tri-state `:ok | :conflict | :unresolvable`
where a DECLARED-but-unresolvable implementer dispatch fails CLOSED with
`unresolvable_dispatch_lineage` (LCP-1 §7.5), a shared lineage root yields `self_report_blocked`,
and `:ok` falls through to plain `assigned_agent_id == agent_id`. The DB CHECK
`stories_reported_done_requires_agent` does NOT cover this — it is satisfied whenever
`implementer_dispatch_id IS NULL` — so the code guard is the enforcement.

**review-complete** — `validate_not_self_review/3` (`progress.ex:2320-2350`) — custody-orphan
backstop first (`progress.ex:2289-2291`), then a **nil reviewer is deliberately PERMITTED**
(`progress.ex:2298-2299`): nil means a human operator on a user-role key. That permit has
THREE parts which must change together:
1. the `exact_role: [:orchestrator, :user]` plug
   (`lib/loopctl_web/controllers/review_record_controller.ex:22-23`), which 403s an `:agent` key
   before any controller code runs — so the `:agent` branch of the controller cond below is
   unreachable today;
2. `LoopctlWeb.ReviewRecordController.create/2`
   (`lib/loopctl_web/controllers/review_record_controller.ex:92-116`), which rejects an
   orchestrator key carrying no `agent_id` and passes a literal `nil` (there is NO "human
   operator" sentinel) for a user key;
3. the `Progress` permit itself.
Then the reviewer's dispatch lineage comparison, then plain `assigned_agent_id` equality.

The reporter/reviewer lineage both come from `Dispatches.lineage_for_api_key/2`
(`lib/loopctl/dispatches.ex:353-363`) — the dispatch that minted the calling key. A key not
minted by a dispatch yields `[]`, which is inert (the agent-id checks still apply); it never
short-circuits a gate.

**The MCP server must NEVER hold both implementer and reviewer keys in the same process.** The 409 errors are the system working correctly — do not add workarounds.

### Before Changing Any Role Requirement

Ask these questions:

1. **Does this weaken chain-of-custody?** If a single session could now both implement and verify/report, the change is WRONG.
2. **Does this give agents destructive capabilities?** Tenant-destructive and custody-critical operations must stay at `role: :user` (or WebAuthn): tenant/project delete, budget/token corrections, cost anomaly resolution, tenant audit-key rotation, break-glass override, single-article `unpublish` and the SET-BASED bulk KB ops (`knowledge_bulk_delete` — the WHOLE action, soft path included, and it also carries an irreversible HARD-delete path — `bulk_publish`, `bulk_unpublish`), and anything in the work-breakdown / chain-of-custody surface. Constructive and metadata work-breakdown operations (create/update epics, stories, dependencies, imports, backfills for pre-loopctl work) are at `role: :orchestrator` so an autonomous orchestrator can compose a project and record state without human intervention. Agents (`role: :agent`) can never write work-breakdown data — only read it. The rule of thumb: if the operation IRREVERSIBLY removes data, or serves as a custody gate, it requires `:user`.

   **KB-content carve-out (#331).** The knowledge-wiki **content** surface is agent-role curation — `knowledge_create`, `knowledge_update` (in-place edit, ID-preserving), `knowledge_archive`/`knowledge_delete` (soft delete → `status: :archived`, row retained), and `knowledge_resolve_conflict` in ALL dispositions (`dismiss`, `supersede`, `merge`). These are the exception to "archive/DELETE ⇒ `:user`" precisely because each is **reversible + audited**: a soft delete retains the row, supersede retires the loser via a reversible `supersedes` link applied only by the privileged nightly executor, and merge produces a new DRAFT (never auto-published). Every mutation is recorded in the append-only, hash-chained audit log (and the per-tenant `kb_curation_log` when enabled). Agent edits/archives are additionally visibility-scoped: an agent can only touch an article it can see, so another agent's `private`/`owner` memory 404s. The human gate bought nothing here (nothing is irreversible or self-approval-shaped) while blocking the intended agent-native curation workflow.

   **What stays `:user` on the KB surface** (`lib/loopctl_web/controllers/article_workflow_controller.ex:37-39`): single-article `unpublish`, plus ALL the SET-BASED bulk ops — `bulk_publish`, `bulk_unpublish`, and the ENTIRE `bulk_delete` action *including its soft path*. Two criteria hold that line together: **set-based blast radius** (one call mutates an unbounded set) AND **irreversibility** (`bulk_delete` carries a hard-delete path that destroys rows). Single-article ops are agent-role because each is reversible + audited. `drafts` and single-article `publish` are `:orchestrator` (`:33`).

   **KB project-scope carve-out (extends #331).** `:kb`-kind project scopes — `create_kb_scope`, `archive_kb_scope`, `restore_kb_scope` (`lib/loopctl_web/controllers/project_controller.ex:25-35`) — are `role: :agent` and deliberately NOT behind `RequireHumanAnchor` (`:52-66`): a `:kb` scope carries no chain-of-custody surface (`RequireWorkProject` bars work attachment), so an agent-rooted tenant may partition its own knowledge. `:work` project create/update/delete stays `:orchestrator`/`:user` AND human-anchored.

   **Tier discoverability, not tier weakening (#505).** An agent-rooted tenant could previously map the tier boundary only by taking a `403 custody_tier_required` per endpoint, which reads as a dead end. `Loopctl.Tenants.TierCapabilities` is now the single derivation of "which surfaces does this tier include", advertised on `GET /api/v1/tenants/me` (`get_tenant`) and embedded in the 403 body itself; a `RequireHumanAnchor` mount may additionally name an `alternative:` (ProjectController names `create_kb_scope`, on `:create` only — an alternative is offered only where it GENUINELY substitutes). The advertised map is bound to the ENFORCED gate mechanically: `TierCapabilities.gated_controllers/0` names the `RequireHumanAnchor`-mounting controllers per human-anchored surface, and `test/loopctl/tenants/tier_capabilities_test.exs` scans the `lib/loopctl_web` sources and fails in both directions — never relax that test to make a new mount pass. The map states its own BOUNDS in the payload (`scope: trust_tier_only`, `applies_to: mutating_actions`): the ROLE gate applies independently (an `allowed` surface can still return `403 insufficient_role`, which now carries a stable `code` and the same capability block) and READS stay open on every surface. On `ProjectController` the tier gate is deliberately mounted BEFORE `RequireRole` on `:create` — controller plugs run in declaration order, and with the role gate first an `:agent`-role key (the default MCP shape) was halted before it could ever see the `create_kb_scope` alternative. **This changed no gate.** If a future change is tempted to let `agent_rooted` through `RequireHumanAnchor`, that is an L0 regression — the human anchor is the root the whole custody chain hangs from, and a tenant opening a custody surface for itself is the exact failure the product exists to prevent. The correct answer to "an agent needs a project row for its repo" is `create_kb_scope`, not a weaker gate.
3. **Does this collapse trust boundaries?** The role hierarchy exists so that agents can't self-promote. Lowering a role requirement is fine for read operations and for operations the role logically needs (orchestrators creating projects). It's wrong for operations that serve as a security gate.
4. **Does this affect RLS?** New tables must use `ENABLE ROW LEVEL SECURITY` (not `FORCE`) since the production role (`schema_admin`) is the table owner without BYPASSRLS.

### Chain of Custody v2 (Epic 26)

The trust model is enforced by six layers:
- **L0** Human + hardware anchor (WebAuthn at tenant signup)
- **L1** Capability tokens (signed, scoped, non-replayable)
- **L2** Database invariants (FK, CHECK, triggers, partial indexes)
- **L3** Independent re-execution (SWE-bench-style verification)
- **L4** Structural role separation (dispatch lineage, rotating verifier)
- **L5** Behavioral detection (lazy-bastard score, CoT sanity)
- **L6** Halt on byzantine (divergent STH, custody halt)

Full spec: `docs/chain-of-custody-v2.md`. Wiki: `https://loopctl.com/wiki/chain-of-custody`.

### Key Distribution (v2 — Dispatch Pattern)

Long-lived env-var keys are replaced by per-dispatch ephemeral keys minted via
`POST /api/v1/dispatches`. Each dispatch carries its lineage path (root → self)
and an ephemeral API key with a bounded TTL. The MCP server v2 tool
`mcp__loopctl__dispatch` handles minting.

Legacy env-var keys (`LOOPCTL_AGENT_KEY`, `LOOPCTL_ORCH_KEY`, etc.) continue to
work during the deprecation window but will be removed at the epic merge.

## Dependency Injection — Config-Based (NOT Opts-Based)

**All external dependencies use behaviours + config-based DI:**

```elixir
# Define the behaviour
defmodule Loopctl.HealthCheck.Behaviour do
  @callback check() :: {:ok, map()} | {:error, term()}
end

# Consumer resolves via Application.get_env
defp health_checker do
  Application.get_env(:loopctl, :health_checker, Loopctl.HealthCheck.Default)
end

# config/test.exs maps to mock
config :loopctl, :health_checker, Loopctl.MockHealthChecker

# Oban workers use compile-time DI
@delivery_client Application.compile_env(:loopctl, :webhook_delivery, Loopctl.Webhooks.ReqDelivery)
```

**NEVER** use `Application.put_env` in test files. **NEVER** pass dependencies as function opts.
Opts are for query parameters (limit, offset, filters) only.

## Test Conventions

### ABSOLUTE RULES

1. **`async: true` on EVERY test file** via DataCase/ConnCase
2. **NEVER `Application.put_env` in tests** — all service swapping via config/test.exs
3. **`Mox.set_mox_from_context(tags)`** in DataCase/ConnCase setup for async isolation
4. **`setup :verify_on_exit!`** on EVERY test file using Mox
5. **Default permissive stubs** in DataCase/ConnCase setup via `stub_all_defaults/0`
6. **Fixtures**: `fixture(:type, attrs)` for DB records, `build(:type, attrs)` for data — defined ONLY in `test/support/fixtures.ex`
7. **Mocks**: defined ONLY in `test/support/mocks.ex` — never `Mox.defmock` in test files
8. **Tenant isolation test** in every context module test — tenant A cannot see tenant B's data

## Run Commands

```bash
mix precommit          # Full quality gate (compile, format, credo --strict, dialyzer, test)
mix test               # Run all tests
mix test --failed      # Re-run failed tests
mix ecto.reset         # Drop, create, migrate
```

## Dialyzer Conventions

- **Never use `@dialyzer` module attributes** to suppress warnings
- `priv/plts/dialyzer_ignore.exs` uses regex patterns for known upstream issues
- Fix root causes instead of adding suppressions

## Key Documents

- **PRD**: `docs/prd.md` — full product requirements
- **User Stories**: `docs/user_stories/epic_N_name/us_N.M.json` — one file per story, one folder per epic
- **Orchestration skills**: `skills/loopctl-*.md` — the orchestration LOOP itself (dispatch, review, verify)
- **Domain skills**: `.claude/skills/<domain>/SKILL.md` — code-map + invariants skills, loaded when you touch that domain (routing table below). Distinct from the `skills/loopctl-*.md` orchestration skills above.
- **Orchestration Guide**: `docs/orchestration-guide.md` — methodology: loop, trust model, checkpointing
- **MCP Server**: `mcp-server/` — statically declared typed tools for Claude Code agents (no curl needed), plus per-tenant generated `cr_*` Context Retriever tools; published as `loopctl-mcp-server` on npm. `mcp-server/README.md` is the source of truth for the list.
- **Build Status**: memory-keeper key `build_status`, channel `loopctl`

### Doc hygiene: NEVER record inventory counts

Do not write counts of things that grow — stories, epics, MCP tools, modules,
skills, articles — into ANY doc (this file, `AGENTS.md`, `README`s, skills).
They are wrong by the next merge and generate pure make-work: a whole PR (#147,
"docs: sync tool count") was once spent resyncing a tool count that has since
churned 57 -> 84 -> 85 -> 102. A review that "fixes" a stale count by writing a
fresh one has fixed nothing; it has reset the rot clock.

Write the **structure or the pointer** instead — a path glob (`us_N.M.json`,
`skills/loopctl-*.md`) or the file that IS the list (`mcp-server/README.md`).
Those stay true as the repo grows.

The narrow exception is a cited config value that explains a BEHAVIOR, not a
tally — e.g. AdminRepo's 3-connection pool (`config/runtime.exs:190`), which is
*why* a heavy read starves the admin pool. Cite it at `file:line` so it can be
re-checked.

### Domain skill routing

| You are touching... | Load |
|---------------------|------|
| roles, auth pipeline, story lifecycle (report / review-complete / verify), capability tokens, dispatch lineage, WebAuthn / human anchor, audit chain | `.claude/skills/chain-of-custody/SKILL.md` |
| tenant scoping, RLS policies, migrations, new tables, the three repos, heavy/vector reads | `.claude/skills/tenancy-rls/SKILL.md` |
| Knowledge Wiki, agent memory, context retriever, hybrid search, novelty gate, embeddings, KB curation permissions | `.claude/skills/knowledge-wiki/SKILL.md` |

## MCP Server

Claude Code agents should use the loopctl MCP tools instead of curl. Install via `npm install loopctl-mcp-server`, then configure in `~/.claude/mcp.json` or `.mcp.json`:

```json
{"mcpServers": {"loopctl": {"command": "npx", "args": ["loopctl-mcp-server"], "env": {"LOOPCTL_SERVER": "https://loopctl.com", "LOOPCTL_ORCH_KEY": "...", "LOOPCTL_AGENT_KEY": "..."}}}}
```

Tools: `mcp__loopctl__list_projects`, `mcp__loopctl__list_stories`, `mcp__loopctl__verify_story`, etc., plus per-tenant `cr_*` Context Retriever tools. See `mcp-server/README.md` for the full list — it is the single source of truth.

---

## Epic 17: Orchestrator Observability

loopctl supports external observability tooling through its API and data model:

- **Two-tier trust model**: `agent_status` (self-reported) vs `verified_status` (orchestrator-set) are
  separate fields on every story. External tools can compare them to detect unverified completions.
- **Orchestrator state checkpointing**: `PUT /orchestrator/state/:project_id` persists orchestrator
  session state (phase, last verified story, decision context). Enables crash recovery and session
  handoff. Versioned with optimistic locking.
- **Audit API**: `GET /stories/:id/history` returns the immutable event log for any story. External
  observers can replay the decision chain for any story without parsing raw session logs.
- **Change feed**: `GET /changes?since=...` lets observer processes poll for all state transitions
  across a project, enabling external dashboards and alerting.
- **`/loopctl:observe` pattern**: Orchestrators can POST structured audit events to loopctl (session
  start/end, rule violations, review outcomes) and query them back via the audit API. This allows
  post-run analysis of orchestrator behavior without coupling to any specific AI tool's log format.

## Epic 28: Agent Memory — `memory_*` vs `knowledge_*`

loopctl gives agents a **private per-agent memory** subsystem (`Loopctl.Memory`,
tables `memories` / `session_memories`) that is DISTINCT from the shared Knowledge
Wiki. Full reference: [`docs/agent-memory.md`](docs/agent-memory.md). Pick the
right surface:

- **`memory_*` (Agent Memory)** — PRIVATE to the caller's `(tenant, subject_id)`
  scope. Use for facts/preferences/observations THIS agent learned about ITS task
  or user and needs to recall later — not worth curating for others. `long_term`
  facts are vector-embedded + semantically recalled; `session` turns are
  chronological + TTL-pruned. Tools: `memory_remember`, `memory_recall`,
  `memory_list`, `memory_forget`.
- **`knowledge_*` (Knowledge Wiki)** — SHARED, curated tenant knowledge (patterns,
  decisions, findings, references), deduped by the novelty gate, linked and
  conflict-resolved. Use when the insight is worth ANOTHER agent reading. Tools:
  `knowledge_create`, `knowledge_search`, etc.

Rule of thumb: *"worth another agent reading?"* → `knowledge_create`. *"a fact only
I need to recall about my own work?"* → `memory_remember`. Scope is derived from
your key server-side — you never pass `tenant_id`/`subject_id`. loopctl is
agent-native (no memory UI); operator oversight is the superadmin API path.

## Epic 30: Context Retriever — three surfaces (`retrieve_*` vs `knowledge_*` vs `memory_*`)

Epic 30 adds a THIRD agent information surface (`Loopctl.ContextRetriever`, tables
`entity_definitions`) alongside the Knowledge Wiki and Agent Memory. Full
reference: [`docs/context-retriever.md`](docs/context-retriever.md). Pick by what
the data IS:

- **`retrieve_*` (Context Retriever)** — GOVERNED, structured access to loopctl's
  own live rows (`projects`/`stories`/`epics`). A tenant admin declares an
  **entity** (typed, server-allowlisted fields) over `/api/v1/entities`; the
  generator emits per-entity `cr_filter_*`/`cr_search_*` tools (dynamic,
  per-tenant, appended to ListTools from `GET /api/v1/retrieve/tools`); a `cr_*`
  call dispatches to `POST /api/v1/retrieve/:entity`. Every query is
  parameterized (no model SQL), dual tenant-scoped (RLS `loopctl_app` role +
  explicit predicate), execute-time allowlist-rechecked, shaped to declared
  columns only, audited (fail-closed), and rate-limited. Use when you'd query
  live operational state by a structured filter or full-text search.
- **`knowledge_*` (Knowledge Wiki)** — SHARED, curated tenant DOCUMENTS. Use when
  the insight is worth another agent reading.
- **`memory_*` (Agent Memory)** — PRIVATE `(tenant, subject_id)` working memory.
  Use for facts only THIS agent needs to recall about its own work.

Rule of thumb: *live structured business row?* → `retrieve_*`. *worth another
agent reading?* → `knowledge_create`. *a fact only I need?* → `memory_remember`.
Defining an entity is a security root (role ≥ `user` + human-anchor); querying is
authenticated-only. You never pass `tenant_id` — scope is key-derived.

## Epic 31: Hybrid (curated + RAG) Knowledge Retrieval

Epic 31 adds a **capability of the Knowledge Wiki layer** — not a fourth agent
surface — that resolves a query to EITHER a governed **curated** answer OR a
semantic/keyword **retrieval** result, on one uniform shape carrying
`meta.provenance` (`:curated`/`:retrieved`). Full reference:
[`docs/knowledge-hybrid-retrieval.md`](docs/knowledge-hybrid-retrieval.md).

- **`Loopctl.Knowledge.hybrid_search/3`** (`knowledge_hybrid_search` tool /
  `POST /api/v1/knowledge/hybrid_search`) — `:curated` wins ONLY when a governed
  curated source's ABSOLUTE (never pool-relative) confidence score clears a
  scale-matched threshold AND beats the best retrieved candidate by a margin AND
  is authoritative (not superseded/conflicted). Otherwise `:retrieved` — a
  near-but-wrong curated doc NEVER wins by default just because a pool is
  sparse. Both branches share identical `results`/`meta` key sets — callers
  branch on `meta.provenance` alone, never on which subsystem answered.
- **Progressive disclosure** (`knowledge_progressive_index` /
  `knowledge_progressive_drill`, `GET /api/v1/knowledge/progressive_index` /
  `GET /api/v1/knowledge/progressive/:id`) — a cheap, top-K-capped, curated-
  preferred topic browse (compact stubs, no bodies) with one hop of `:relates_to`
  hub enrichment, then a full-body drill into a chosen stub. A fuzzy/paraphrased
  topic can miss a lexically-dissimilar curated article — use `hybrid_search/3`
  when you need the governed provenance decision instead.
- **#305/#306 are the same feature** (this epic implements both) — recommend
  closing one as a duplicate of the other rather than tracking them separately.

## Elixir / Phoenix guidelines

These are the stock `phx.new` rules, condensed. Each line is a hard rule.

### Elixir
- Lists have no index access (`list[i]`) — use `Enum.at/2`, pattern match, or `List`.
- No `else if` / `elsif` — use `cond` or `case` for multiple conditionals.
- Block expressions (`if`/`case`/`cond`) must have their result bound to a var; never rebind inside the block (`socket = if ... do assign(...) end`, not assigning inside).
- Use `with` for chaining `{:ok, _}` / `{:error, _}`.
- One module per file (nesting risks cyclic deps / compile errors).
- No map-access syntax on structs (`struct[:field]`) — access fields directly, or `Ecto.Changeset.get_field/2` for changesets.
- Use stdlib `Time`/`Date`/`DateTime`/`Calendar` for date/time; add no deps except `date_time_parser` for parsing.
- Never `String.to_atom/1` on user input (memory leak).
- Predicate fns end in `?`, not an `is_` prefix (reserve `is_` for guards).
- `DynamicSupervisor`/`Registry` need a `name:` in the child spec.
- `Task.async_stream/3` for concurrent enumeration with backpressure (usually `timeout: :infinity`).

### Mix
- Read `mix help <task>` before using a task.
- Debug tests with `mix test path/to_test.exs` or `mix test --failed`.
- Avoid `mix deps.clean --all` (almost never needed).

### Phoenix
- A `scope` block's alias prefixes all routes inside it — never add your own alias; watch for double prefixes.
- `Phoenix.View` is gone — don't use it.
- `mix precommit` when done. HTTP via `Req` only (not httpoison/tesla/httpc).

### Ecto
- Preload associations that templates will access.
- `import Ecto.Query` (and friends) in `seeds.exs`.
- Schema fields use `:string` even for `:text` columns.
- `validate_number/2` has no `:allow_nil` option (validations already skip nil/absent changes).
- Access changeset fields via `Ecto.Changeset.get_field/2`.
- Programmatic fields (e.g. `user_id`) are never in `cast` — set them explicitly on the struct.

### HEEx
- Templates use `~H` or `.heex` files, never `~E`.
- Forms: `Phoenix.Component.form/1` + `inputs_for/1` + `to_form/2`; never `Phoenix.HTML.form_for`/`inputs_for`. Access fields as `@form[:field]`.
- Unique DOM IDs on forms/buttons/key elements (for tests).
- App-wide imports go in `my_app_web.ex`'s `html_helpers` block.
- Literal `{`/`}` in `<pre>`/`<code>` needs `phx-no-curly-interpolation` on the parent tag.
- `class` conditionals must use list syntax and wrap inline `if` in parens:
  `class={["px-2", @flag && "py-5", if(@cond, do: "a", else: "b")]}`. Bare `{...}` without `[]` is a compile error.
- Generate template content with `<%= for item <- @col do %>`, never `<% Enum.each %>`.
- Comments are `<%!-- comment --%>`.
- Interpolation: use `{...}` in attrs and in tag bodies; use `<%= ... %>` ONLY for block constructs (if/cond/case/for) inside tag bodies. Never `<%= %>` inside an attribute.

### LiveView
- No `live_redirect`/`live_patch` — use `<.link navigate=/patch=>` and `push_navigate`/`push_patch`.
- Avoid LiveComponents unless strongly justified.
- Name LiveViews `AppWeb.FooLive`; the `:browser` scope is already aliased (`live "/foo", FooLive`).
- A `phx-hook` that manages its own DOM also needs `phx-update="ignore"`.
- No inline `<script>` in HEEx — put JS in `assets/js` and wire it through `app.js`.

#### Streams
- Use streams for collections (avoids memory ballooning). Parent needs a DOM `id` + `phx-update="stream"`; each child uses the stream-provided id as its DOM id:
  ```
  <div id="messages" phx-update="stream">
    <div :for={{id, msg} <- @streams.messages} id={id}>{msg.text}</div>
  </div>
  ```
- Streams aren't enumerable — to filter/refresh, refetch and re-stream with `reset: true`.
- No built-in count or empty-state: track count in a separate assign; empty state via `<div class="hidden only:block">…</div>` (only works when it's the sole sibling of the for-comprehension).
- Never `phx-update="append"`/`"prepend"`.

#### LiveView tests
- `Phoenix.LiveViewTest` + `LazyHTML`; forms via `render_submit/2` / `render_change/2`.
- Assert on elements and IDs (`has_element?/2`, `element/2`), never raw HTML; test outcomes, not implementation.
- Debug by scoping output with `LazyHTML.from_fragment` + `LazyHTML.filter`.

#### Forms
- From params: `to_form(params)` (string keys), or `to_form(params, as: :user)` to nest.
- From changeset: `changeset |> to_form()` — `:as` is auto-computed; submit yields `%{"user" => params}`.
- Always drive the UI from a `to_form/2` assign: `<.form for={@form} id="x-form">` + `<.input field={@form[:field]}>`. FORBIDDEN: passing a changeset to `<.form>`, or `<.form let={f}>`.

### Phoenix v1.8
- LiveView templates begin with `<Layouts.app flash={@flash} ...>` (wraps all content); `Layouts` is already aliased.
- `current_scope` errors → move routes to the proper `live_session` and pass `current_scope` to `<Layouts.app>`.
- `<.flash_group>` only inside `layouts.ex`.
- Icons via `<.icon name="hero-x-mark" class="w-5 h-5"/>`, never `Heroicons`.
- Use the imported `<.input>` for inputs; overriding its `class` drops ALL default classes (style fully).

### CSS / JS
- Tailwind v4: no `tailwind.config.js`. Keep app.css's `@import "tailwindcss" source(none);` + `@source` lines.
- No `@apply`; hand-write Tailwind components (no daisyUI) for a unique look.
- Only `app.js` / `app.css` bundles ship — import vendor deps there; no external `src`/`href`, no inline `<script>`.
- UI/UX: world-class, usable, modern — subtle micro-interactions, clean typography/spacing/balance, delightful hover/loading/transition details.

### Authentication (`phx.gen.auth`)
- Handle auth at the router level with proper redirects.
- It creates two live_sessions: `:current_user` (works with or without auth) and `:require_authenticated_user` (auth required). Both assign `@current_scope` — NOT `@current_user`.
- Access the user via `current_scope.user`; never use `@current_user` in templates/LiveViews.
- Always state which scope / live_session / pipeline a route goes in, AND WHY.
- Auth-required routes → the existing `:require_authenticated_user` block. Optional-auth routes → the existing `:current_user` block.
- Never duplicate a `live_session` name — all routes for a name live in one block.