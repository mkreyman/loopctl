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

**Design spec:** the Chain of Custody v2 design lives in `docs/chain-of-custody-v2.md`.
Sections 2.1 and 9 in particular establish the human-rooted signup ceremony (WebAuthn)
and the chain-of-custody invariants that the rest of the system relies on. Consult it
before changing anything in the auth, signup, or audit pipelines.

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
2. **Does this give agents destructive capabilities?** ALL destructive operations (any DELETE, archive, budget/token corrections, cost anomaly resolution, tenant audit key rotation) must stay at `role: :user`. Constructive and metadata work-breakdown operations (create/update epics, stories, dependencies, imports, backfills for pre-loopctl work) are at `role: :orchestrator` so an autonomous orchestrator can compose a project and record state without human intervention. Agents (`role: :agent`) can never write work-breakdown data — only read it. The rule of thumb: if the operation REMOVES data, it requires `:user`.
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
- **User Stories**: `docs/user_stories/epic_N_name/us_N.M.json` — 60 stories across 15 epics
- **Skills**: `skills/loopctl-*.md` — 6 orchestration skills
- **Orchestration Guide**: `docs/orchestration-guide.md` — methodology: loop, trust model, checkpointing
- **MCP Server**: `mcp-server/` — 65 typed tools for Claude Code agents (no curl needed), published as `loopctl-mcp-server` on npm
- **Build Status**: memory-keeper key `build_status`, channel `loopctl`

## MCP Server

Claude Code agents should use the loopctl MCP tools instead of curl. Install via `npm install loopctl-mcp-server`, then configure in `~/.claude/mcp.json` or `.mcp.json`:

```json
{"mcpServers": {"loopctl": {"command": "npx", "args": ["loopctl-mcp-server"], "env": {"LOOPCTL_SERVER": "https://loopctl.com", "LOOPCTL_ORCH_KEY": "...", "LOOPCTL_AGENT_KEY": "..."}}}}
```

Tools: `mcp__loopctl__list_projects`, `mcp__loopctl__list_stories`, `mcp__loopctl__verify_story`, etc. (65 total). See `mcp-server/README.md` for the full list.

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