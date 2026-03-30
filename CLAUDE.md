# loopctl

Agent-native project state store for AI development loops.
Stack: Elixir 1.18 / Phoenix 1.8 (API-only), PostgreSQL with RLS, Oban, Req, Cloak.

**Also read [AGENTS.md](AGENTS.md)** — contains Phoenix 1.8 framework guidelines, Elixir conventions, Ecto patterns.

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
- **Build Status**: memory-keeper key `build_status`, channel `loopctl`

## Chain-of-Custody Enforcement

The API enforces that nobody marks their own work as done. Three identity gates check that the
caller's agent ID differs from the story's assigned agent ID:

- `POST /stories/:id/report` — returns `409 self_report_blocked` if caller == assigned_agent_id
- `POST /stories/:id/review-complete` — returns `409 self_review_blocked` if caller == assigned_agent_id
- `POST /stories/:id/verify` — returns `409 self_verify_blocked` if caller == assigned_agent_id

The implementer's final action is `POST /stories/:id/request-review`. All three subsequent steps
(report, review-complete, verify) must come from different agents.

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
