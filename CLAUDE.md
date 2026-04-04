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
├── schema.ex          # Base schema macro
└── repo.ex            # Ecto Repo

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
6. Two Repos: `Loopctl.Repo` (RLS enforced) and `Loopctl.AdminRepo` (BYPASSRLS for superadmin)

## Security & Trust Model — Mandatory Review Checklist

**EVERY change to loopctl must be evaluated against this checklist before merging.**

### Role Hierarchy

`superadmin (4) > user (3) > orchestrator (2) > agent (1)`

Higher roles can access lower-role endpoints. The hierarchy is enforced by `RequireRole` plug.

### Chain-of-Custody Enforcement

The API enforces that nobody marks their own work as done:
- `POST /stories/:id/report` — `409 self_report_blocked` if caller == assigned_agent_id
- `POST /stories/:id/review-complete` — `409 self_review_blocked` if caller == assigned_agent_id
- `POST /stories/:id/verify` — `409 self_verify_blocked` if caller == assigned_agent_id

**The MCP server must NEVER hold both implementer and reviewer keys in the same process.** The 409 errors are the system working correctly — do not add workarounds.

### Before Changing Any Role Requirement

Ask these questions:

1. **Does this weaken chain-of-custody?** If a single session could now both implement and verify/report, the change is WRONG.
2. **Does this give agents destructive capabilities?** Destructive operations (DELETE, archive) must stay at `role: :user`. Agents and orchestrators should not be able to delete projects, budgets, or resolve anomalies via MCP tools.
3. **Does this collapse trust boundaries?** The role hierarchy exists so that agents can't self-promote. Lowering a role requirement is fine for read operations and for operations the role logically needs (orchestrators creating projects). It's wrong for operations that serve as a security gate.
4. **Does this affect RLS?** New tables must use `ENABLE ROW LEVEL SECURITY` (not `FORCE`) since the production role (`schema_admin`) is the table owner without BYPASSRLS.

### Key Distribution Rules

- `LOOPCTL_AGENT_KEY` — agent role, used by implementation agents
- `LOOPCTL_ORCH_KEY` — orchestrator role, used by the orchestrator for reads and non-custody operations
- `LOOPCTL_REVIEWER_KEY` — separate agent identity, used ONLY via curl by review agents (never in the same MCP server as the agent key)
- `LOOPCTL_USER_KEY` — user role, used ONLY via curl for destructive/admin operations

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
- **User Stories**: `docs/user_stories/epic_N_name/us_N.M.json` — 60 stories across 15 epics
- **Skills**: `skills/loopctl-*.md` — 6 orchestration skills
- **Orchestration Guide**: `docs/orchestration-guide.md` — methodology: loop, trust model, checkpointing
- **MCP Server**: `mcp-server/` — 24 typed tools for Claude Code agents (no curl needed), published as `loopctl-mcp-server` on npm
- **Build Status**: memory-keeper key `build_status`, channel `loopctl`

## MCP Server

Claude Code agents should use the loopctl MCP tools instead of curl. Install via `npm install loopctl-mcp-server`, then configure in `~/.claude/mcp.json` or `.mcp.json`:

```json
{"mcpServers": {"loopctl": {"command": "npx", "args": ["loopctl-mcp-server"], "env": {"LOOPCTL_SERVER": "https://loopctl.com", "LOOPCTL_ORCH_KEY": "...", "LOOPCTL_AGENT_KEY": "..."}}}}
```

Tools: `mcp__loopctl__list_projects`, `mcp__loopctl__list_stories`, `mcp__loopctl__verify_story`, etc. (24 total). See `mcp-server/README.md` for the full list.

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
