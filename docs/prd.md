# loopctl — Product Requirements Document

**Version:** 1.0
**Date:** 2026-03-26
**Author:** Michael Kreyman
**Domain:** loopctl.com
**Repository:** github.com/mkreyman/loopctl

---

## 1. Executive Summary

loopctl is an open-source, agent-native project state store for AI development loops. It provides a multi-tenant REST API and CLI for AI agents and orchestrators to track project work breakdown, report progress, verify deliverables, and maintain audit trails — without any human UI.

### The Problem

When AI coding agents implement large projects (25+ epics, 185+ stories), there is no reliable way to:
- Track what work has actually been completed vs. what agents claim is done
- Independently verify that deliverables match specifications
- Coordinate multiple implementation agents working in parallel
- Resume orchestration after session interruptions
- Maintain an audit trail of who did what and when

In practice, implementing agents fabricate review results, skip UI implementation while claiming backend is "complete," and self-report success without producing the required artifacts. A project-wide audit of one 185-story project revealed only ~40% of backend functionality had corresponding UI — despite agents reporting all 25 epics as complete.

### The Solution

loopctl is a **dumb state store** that separates self-reported progress from independently verified progress. Implementation agents write their own status updates. An independent orchestrator (a separate system, not part of loopctl) reads those updates, performs verification, and records its findings. The two-tier trust model makes it structurally impossible for implementing agents to mark their own work as verified.

loopctl is not an orchestrator. It does not make decisions, execute code, or run tests. It stores state, enforces access control, and serves data.

### Key Principles

1. **Agent-first** — every interface (API, CLI, data formats) is optimized for programmatic consumption by AI agents, not human eyeballs
2. **Dumb store** — no business logic, no workflow engine, no decision-making. Store state, enforce access control, serve data.
3. **Trust nothing** — two-tier status model ensures implementing agents cannot mark their own work as verified
4. **Resume anywhere** — orchestrator state is persisted, so any session can pick up where the last one left off
5. **Multi-tenant from day one** — PostgreSQL Row Level Security, API key isolation, ready for SaaS
6. **Maximum flexibility** — configurable schemas, tenant-level settings, extensible metadata

---

## 2. Target Users

### Primary: AI Agents

AI coding agents (Claude Code sub-agents, Cursor agents, Copilot agents, etc.) that:
- Implement features from user story specifications
- Report progress and artifacts via CLI or API
- Self-register with a tenant to receive an agent API key

### Secondary: AI Orchestrators

Orchestrator agents (Claude Code skills, custom scripts) that:
- Query loopctl for the next assignable work
- Poll for agent progress updates
- Record independent verification results
- Checkpoint their own state for crash recovery

### Tertiary: Human Developers

Developers who:
- Import user stories into loopctl from JSON files
- Check project status via CLI
- Review audit trails
- Manage tenants, API keys, and configurations

---

## 3. Tech Stack

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| Language | Elixir 1.18+ / Erlang OTP 27+ | Battle-tested for concurrent, fault-tolerant systems |
| Framework | Phoenix 1.8+ (API-only, no LiveView) | JSON API with channels for future real-time features |
| Database | PostgreSQL 16+ with RLS | Row Level Security for multi-tenancy |
| Background Jobs | Oban | Webhook delivery, cleanup tasks |
| Auth | API keys (SHA-256 hashed), JWT (for future sessions) | Simple, stateless, agent-friendly |
| HTTP Client | Req | Webhook delivery, future integrations |
| CLI | Escript binary | Single binary distribution, no runtime dependency |
| CI/CD | GitHub Actions → self-hosted runner (beelink) | Same pattern as open_brain |
| Testing | ExUnit, Mox, Req.Test | Standard Elixir testing stack |
| IDs | Binary UUIDs | Globally unique, no sequential guessing |
| Encryption | Cloak (AES-256-GCM) | API key secrets, webhook signing secrets at rest |

---

## 4. Architecture Overview

### 4.1 Multi-Tenancy (3 Layers)

1. **Application layer**: Every query scoped by `tenant_id` via context functions
2. **Database layer**: PostgreSQL RLS policies on all tenant-scoped tables — defense in depth
3. **API layer**: API key → tenant resolution in auth pipeline; requests cannot cross tenant boundaries

### 4.2 Authentication Pipeline

```
ExtractApiKey → ResolveApiKey (SHA-256 lookup) → SetTenant (RLS SET) → RequireRole (role guard) → RateLimiter
```

### 4.3 Role-Based Access Control

Four roles, three tenant-scoped and one app-wide:

| Role | Scope | Capabilities |
|------|-------|-------------|
| `superadmin` | App-wide | Full CRUD on all entities across all tenants. Impersonation. System stats. |
| `user` | Tenant | Manage tenant settings, API keys, agents, projects. Import/export. Full read access. |
| `orchestrator` | Tenant | Write `verified_status` and verification results. Write orchestrator state. Read everything. |
| `agent` | Tenant | Write `agent_status` and artifact reports. Self-register. Read own assignments. |

### 4.4 Two-Tier Trust Model

Every story has two independent status tracks:

```
agent_status:     pending → contracted → assigned → implementing → reported_done
verified_status:  unverified → verified → rejected → unverified (auto-reset on rejection)
```

- **Only `agent` role keys** can write to `agent_status`
- **Only `orchestrator` role keys** can write to `verified_status`
- When `verified_status` is set to `rejected`, `agent_status` auto-resets to `pending`
- Every status transition is recorded in the audit trail with timestamp, actor, and previous state
- The `contracted` step requires the agent to acknowledge the story's acceptance criteria before being assigned. This prevents the pattern where agents claim stories without reading requirements.
- Iteration count tracks review-fix cycles per story. High iteration counts signal evaluation prompt calibration opportunities.

### 4.5 Change Feed (Dual Mode)

**Polling:**
- `GET /api/v1/changes?since=<ISO8601>&project_id=<id>` — returns all state changes since timestamp
- Stateless, no server-side cursor management
- Default for orchestrators

**Webhooks:**
- Tenant configures a webhook URL; server pushes events on state changes
- Events: `story.status_changed`, `story.verified`, `story.rejected`, `artifact.reported`, `agent.registered`, `agent.stalled`
- Signed (HMAC-SHA256), retried with exponential backoff via Oban
- Optional per-tenant, configurable filters (by project, event type)

### 4.6 Stall Detection (Future)

In practice, with a 1-commit-per-story discipline and small contained stories, agent stalling has not been a real problem. Agents may produce wrong work, but they don't freeze.

Stall detection is deferred to a future version. The architecture supports it (timestamps on all status transitions, `last_seen_at` on agents) but no active stall detection, heartbeat endpoints, or stall-related queries are included in v1.

---

## 5. Data Model

### 5.1 Core Entities

#### tenants
The organizational unit. All data is scoped to a tenant.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| name | string | Display name |
| slug | string | URL-safe, unique |
| email | string | Contact email |
| settings | jsonb | Tenant-level configuration (see 5.3) |
| status | enum | `active`, `suspended`, `deactivated` |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

#### api_keys
Authentication tokens. Hashed, never stored in plaintext after creation.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants (NULL for superadmin keys) |
| name | string | Human-readable label ("orchestrator-prod", "agent-worker-1") |
| key_hash | string | SHA-256 hash of the raw key |
| key_prefix | string | First 8 chars of raw key, for identification |
| role | enum | `superadmin`, `user`, `orchestrator`, `agent` |
| agent_id | uuid | FK → agents (NULL unless role=agent) |
| last_used_at | utc_datetime | Updated on each authenticated request |
| expires_at | utc_datetime | NULL = never expires |
| revoked_at | utc_datetime | NULL = active |
| inserted_at | utc_datetime | |

#### projects
A codebase being tracked.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| name | string | Display name |
| slug | string | Unique within tenant |
| repo_url | string | GitHub/GitLab URL |
| description | text | |
| tech_stack | string | "elixir/phoenix", "typescript/fastify", etc. |
| status | enum | `active`, `archived` |
| metadata | jsonb | Extensible |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

#### epics
A group of related stories within a project.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| project_id | uuid | FK → projects |
| number | integer | Epic number (e.g., 1, 2, 3) |
| title | string | |
| description | text | |
| phase | string | "p0_foundation", "mvp_core", etc. |
| position | integer | Ordering within phase |
| metadata | jsonb | Extensible |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

#### epic_dependencies
Directed edges: epic A must complete before epic B can start.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| epic_id | uuid | FK → epics (the dependent) |
| depends_on_epic_id | uuid | FK → epics (the prerequisite) |
| inserted_at | utc_datetime | |

#### stories
The atomic unit of work.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| epic_id | uuid | FK → epics |
| number | string | Story number within epic (e.g., "2.1", "2.2") |
| title | string | |
| description | text | |
| acceptance_criteria | jsonb | Structured criteria from user story |
| estimated_hours | decimal | Optional |
| agent_status | enum | `pending`, `contracted`, `assigned`, `implementing`, `reported_done` |
| verified_status | enum | `unverified`, `verified`, `rejected` |
| assigned_agent_id | uuid | FK → agents, NULL if unassigned |
| assigned_at | utc_datetime | |
| reported_done_at | utc_datetime | |
| verified_at | utc_datetime | |
| rejected_at | utc_datetime | |
| rejection_reason | text | |
| metadata | jsonb | Extensible |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

#### story_dependencies
Directed edges: story A must be verified before story B can be assigned.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| story_id | uuid | FK → stories (the dependent) |
| depends_on_story_id | uuid | FK → stories (the prerequisite) |
| inserted_at | utc_datetime | |

#### agents
Registered AI agents that perform work.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| name | string | Agent identifier ("worker-1", "orchestrator-main") |
| agent_type | enum | `orchestrator`, `implementer` |
| status | enum | `active`, `idle`, `deactivated` |
| last_seen_at | utc_datetime | Updated on any authenticated API call |
| metadata | jsonb | Agent capabilities, configuration |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

> **Future: Agent Runs.** A dedicated `agent_runs` table tracking per-story execution history (start, end, duration, outcome) is planned for a future version. For v1, the audit log captures agent activity.

#### artifact_reports
What an agent or orchestrator found after a story was implemented.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| story_id | uuid | FK → stories |
| reported_by | enum | `agent`, `orchestrator` |
| reporter_agent_id | uuid | FK → agents |
| artifact_type | string | Free-form: "migration", "schema", "context", "live_view", "test", "route", "commit_diff", etc. |
| path | string | File path or git ref |
| exists | boolean | Does the artifact actually exist? |
| details | jsonb | Flexible — diff content, function names, line counts, whatever the reporter provides |
| inserted_at | utc_datetime | |

#### verification_results
The orchestrator's independent assessment of a story.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| story_id | uuid | FK → stories |
| orchestrator_agent_id | uuid | FK → agents |
| result | enum | `pass`, `fail`, `partial` |
| summary | text | Human-readable summary |
| findings | jsonb | Structured findings (issues found, artifacts missing, etc.) |
| review_type | string | "enhanced_review", "artifact_check", "manual", etc. |
| iteration | integer | 1-indexed attempt number for this story |
| inserted_at | utc_datetime | |

#### orchestrator_state
Key-value checkpointing for orchestrator crash recovery.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| project_id | uuid | FK → projects |
| state_key | string | Namespaced key ("main", "backup", "experiment-1") |
| state_data | jsonb | Arbitrary orchestrator state |
| version | integer | Optimistic locking |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

#### audit_log
Immutable append-only record of every mutation.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants (NULL for superadmin actions) |
| entity_type | string | "story", "epic", "project", "agent", etc. |
| entity_id | uuid | |
| action | string | "created", "updated", "status_changed", "verified", "rejected", etc. |
| actor_type | string | "api_key", "system", "superadmin" |
| actor_id | uuid | API key ID or agent ID |
| actor_label | string | Human-readable ("agent:worker-1", "orchestrator:main") |
| old_state | jsonb | Previous state (for updates) |
| new_state | jsonb | New state |
| metadata | jsonb | Additional context |
| inserted_at | utc_datetime | Immutable — no updated_at |

#### webhooks
Tenant-configured outbound event subscriptions.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| url | string | Delivery target |
| signing_secret_encrypted | binary | AES-256-GCM encrypted (Cloak) |
| events | {:array, :string} | List of event types to subscribe to |
| project_id | uuid | FK → projects, NULL = all projects |
| active | boolean | |
| consecutive_failures | integer | Auto-disable after threshold |
| last_delivery_at | utc_datetime | |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

#### webhook_events
Outbound event queue, processed by Oban.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| webhook_id | uuid | FK → webhooks |
| event_type | string | "story.status_changed", "story.verified", etc. |
| payload | jsonb | Event data |
| status | enum | `pending`, `delivered`, `failed`, `exhausted` |
| attempts | integer | |
| last_attempt_at | utc_datetime | |
| delivered_at | utc_datetime | |
| error | text | Last error message |
| inserted_at | utc_datetime | |

#### skills
Versioned orchestrator prompts, review instructions, and agent skill definitions.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| project_id | uuid | FK → projects, nullable (null = tenant-wide, not project-specific) |
| name | string | Namespaced identifier, e.g. "loopctl:review", "loopctl:verify-artifacts" |
| description | text | What this skill does |
| current_version | integer | Points to latest version number |
| status | enum | `active`, `archived` |
| metadata | jsonb | Extensible (tags, category, etc.) |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

#### skill_versions
Immutable snapshots of skill prompt text. Each prompt change creates a new version.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| skill_id | uuid | FK → skills |
| version | integer | 1-indexed, auto-incremented per skill |
| prompt_text | text | The full skill prompt/instructions |
| changelog | text | What changed from previous version |
| created_by | string | Actor label (agent name, "user", etc.) |
| metadata | jsonb | Extensible |
| inserted_at | utc_datetime | Immutable — no updated_at |

#### skill_results
Links verification results to the skill version that produced them, enabling performance comparison across versions.

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| skill_version_id | uuid | FK → skill_versions |
| verification_result_id | uuid | FK → verification_results |
| story_id | uuid | FK → stories |
| metrics | jsonb | findings_count, false_positive_count, true_positive_count, review_duration_ms, iteration |
| inserted_at | utc_datetime | Immutable — no updated_at |

### 5.2 Webhook Event Types

| Event | Trigger | Payload includes |
|-------|---------|-----------------|
| `story.status_changed` | Any `agent_status` change | story_id, old_status, new_status, agent_id |
| `story.verified` | `verified_status` → `verified` | story_id, orchestrator_id, verification_result |
| `story.rejected` | `verified_status` → `rejected` | story_id, orchestrator_id, reason, findings |
| `story.auto_reset` | `agent_status` reset to `pending` after rejection | story_id, reason |
| `epic.completed` | All stories in epic verified | epic_id, story_count, duration |
| `artifact.reported` | New artifact report submitted | story_id, artifact_type, reported_by |
| `agent.registered` | New agent self-registers | agent_id, agent_type, name |
| `project.imported` | Bulk import completed | project_id, epic_count, story_count |

### 5.3 Tenant Settings (jsonb)

Tenant-level configuration stored in `tenants.settings`:

```json
{
  "max_concurrent_agents": 10,
  "max_projects": 50,
  "max_stories_per_project": 1000,
  "max_api_keys": 100,
  "max_webhooks": 10,
  "webhook_max_consecutive_failures": 10,
  "rate_limit_requests_per_minute": 300,
  "auto_reset_on_rejection": true,
  "timezone": "UTC"
}
```

Settings resolve in order: tenant override → plan defaults (future) → hardcoded fallback.

---

## 6. API Specification

All endpoints are under `/api/v1/`. All request and response bodies are JSON. Authentication is via `Authorization: Bearer <api_key>` header.

### 6.1 Authentication & Tenants

| Method | Path | Role | Description |
|--------|------|------|-------------|
| POST | /tenants/register | Public | Self-service signup. Creates tenant + first user API key. Returns raw API key (only time it's visible). |
| GET | /tenants/me | user+ | Current tenant profile and settings |
| PATCH | /tenants/me | user | Update tenant settings |
| POST | /api_keys | user | Create new API key (specify role, optional agent_id) |
| GET | /api_keys | user | List API keys (key_prefix + metadata, never the full key) |
| DELETE | /api_keys/:id | user | Revoke an API key |
| POST | /api_keys/:id/rotate | user | Rotate: create new key, set grace period on old key |

### 6.2 Projects

| Method | Path | Role | Description |
|--------|------|------|-------------|
| POST | /projects | user | Create project |
| GET | /projects | agent+ | List projects |
| GET | /projects/:id | agent+ | Get project with epic/story counts |
| PATCH | /projects/:id | user | Update project |
| DELETE | /projects/:id | user | Archive project (soft delete) |
| POST | /projects/:id/import | user | Bulk import epics + stories + dependencies from JSON |
| GET | /projects/:id/export | agent+ | Export project as JSON |
| GET | /projects/:id/progress | agent+ | Progress summary: stories by status, epics complete/total, % verified |

### 6.3 Epics

| Method | Path | Role | Description |
|--------|------|------|-------------|
| POST | /projects/:project_id/epics | user | Create epic |
| GET | /projects/:project_id/epics | agent+ | List epics with story counts and completion % |
| GET | /epics/:id | agent+ | Get epic with stories |
| PATCH | /epics/:id | user | Update epic |
| DELETE | /epics/:id | user | Delete epic (cascade stories) |
| GET | /epics/:id/progress | agent+ | Epic progress: story breakdown by status |

### 6.4 Stories

| Method | Path | Role | Description |
|--------|------|------|-------------|
| POST | /epics/:epic_id/stories | user | Create story |
| GET | /epics/:epic_id/stories | agent+ | List stories in epic |
| GET | /stories/:id | agent+ | Get story with dependencies, artifacts, latest verification |
| PATCH | /stories/:id | user | Update story metadata (not status — use dedicated endpoints) |
| DELETE | /stories/:id | user | Delete story |
| GET | /stories/ready | agent+ | Stories where all deps verified, agent_status=pending. Filterable by project_id, epic_id. |
| GET | /stories/blocked | agent+ | Stories waiting on unverified dependencies |

### 6.5 Story Status (Agent)

| Method | Path | Role | Description |
|--------|------|------|-------------|
| POST | /stories/:id/contract | agent | Set agent_status=contracted. Agent must echo story_title + ac_count to prove it read the story. |
| POST | /stories/:id/claim | agent | Set agent_status=assigned, assign agent. Requires agent_status=contracted. |
| POST | /stories/:id/start | agent | Set agent_status=implementing. Must be assigned to this agent. |
| POST | /stories/:id/report | agent | Set agent_status=reported_done. Optionally include artifact report. |
| POST | /stories/:id/unclaim | agent | Release assignment. Resets to pending. |

### 6.6 Story Verification (Orchestrator)

| Method | Path | Role | Description |
|--------|------|------|-------------|
| POST | /stories/:id/verify | orchestrator | Set verified_status=verified. Include verification result. |
| POST | /stories/:id/reject | orchestrator | Set verified_status=rejected, reason. Auto-resets agent_status to pending. |
| GET | /stories/:id/verifications | orchestrator+ | List all verification results for a story |

### 6.7 Artifacts

| Method | Path | Role | Description |
|--------|------|------|-------------|
| POST | /stories/:id/artifacts | agent+ | Submit artifact report |
| GET | /stories/:id/artifacts | agent+ | List artifact reports for a story |

### 6.8 Agents

| Method | Path | Role | Description |
|--------|------|------|-------------|
| POST | /agents/register | agent | Self-register: provide name, type. Returns agent record. API key must have role=agent. |
| GET | /agents | orchestrator+ | List agents with status, last_seen_at |
| GET | /agents/:id | orchestrator+ | Agent detail |

### 6.9 Orchestrator State

| Method | Path | Role | Description |
|--------|------|------|-------------|
| PUT | /orchestrator/state/:project_id | orchestrator | Save state (upsert by state_key). Optimistic locking via version. |
| GET | /orchestrator/state/:project_id | orchestrator | Get state. Optional state_key param. |
| GET | /orchestrator/state/:project_id/history | orchestrator | State version history |

### 6.10 Change Feed

| Method | Path | Role | Description |
|--------|------|------|-------------|
| GET | /changes | agent+ | Changes since timestamp. Filterable by project_id, entity_type, action. |

### 6.11 Audit Trail

| Method | Path | Role | Description |
|--------|------|------|-------------|
| GET | /audit | user+ | Query audit log. Filter by entity_type, entity_id, action, actor, date range. |
| GET | /stories/:id/history | agent+ | Shortcut: full audit trail for a story |

### 6.12 Webhooks

| Method | Path | Role | Description |
|--------|------|------|-------------|
| POST | /webhooks | user | Create webhook subscription |
| GET | /webhooks | user | List webhooks |
| PATCH | /webhooks/:id | user | Update webhook (URL, events, active) |
| DELETE | /webhooks/:id | user | Delete webhook |
| GET | /webhooks/:id/deliveries | user | List recent delivery attempts |
| POST | /webhooks/:id/test | user | Send a test event |

### 6.13 Superadmin

All superadmin endpoints require a superadmin API key.

| Method | Path | Description |
|--------|------|-------------|
| GET | /admin/tenants | List all tenants with stats |
| GET | /admin/tenants/:id | Tenant detail |
| PATCH | /admin/tenants/:id | Update tenant (status, settings) |
| POST | /admin/tenants/:id/suspend | Suspend tenant |
| POST | /admin/tenants/:id/activate | Re-activate tenant |
| GET | /admin/stats | System-wide stats (tenants, projects, stories, agents, active runs) |
| GET | /admin/audit | Cross-tenant audit log query |
| * | /api/v1/* + X-Impersonate-Tenant header | Impersonate: execute any request as if authenticated as the specified tenant |

### 6.14 Dependencies

| Method | Path | Role | Description |
|--------|------|------|-------------|
| POST | /epic_dependencies | user | Create epic dependency |
| DELETE | /epic_dependencies/:id | user | Remove epic dependency |
| GET | /projects/:id/epic_dependencies | agent+ | List all epic dependencies (graph edges) |
| POST | /story_dependencies | user | Create story dependency |
| DELETE | /story_dependencies/:id | user | Remove story dependency |
| GET | /epics/:id/story_dependencies | agent+ | List all story dependencies within epic |
| GET | /projects/:id/dependency_graph | agent+ | Full project dependency graph (epics + stories) |

### 6.15 Bulk Operations

| Method | Path | Role | Description |
|--------|------|------|-------------|
| POST | /stories/bulk/claim | agent | Claim multiple stories at once |
| POST | /stories/bulk/verify | orchestrator | Verify multiple stories at once |
| POST | /stories/bulk/reject | orchestrator | Reject multiple stories at once |

### 6.16 Skills

| Method | Path | Role | Description |
|--------|------|------|-------------|
| POST | /skills | user | Create skill (creates v1 with prompt_text) |
| GET | /skills | agent+ | List skills (filterable by project_id, name pattern, status) |
| GET | /skills/:id | agent+ | Get skill with current version prompt_text |
| PATCH | /skills/:id | user | Update metadata, description, status (NOT prompt — that's a new version) |
| DELETE | /skills/:id | user | Archive skill (soft delete) |
| POST | /skills/:id/versions | user | Create new version (increments version, stores prompt_text + changelog) |
| GET | /skills/:id/versions | agent+ | List all versions with metadata (prompt_text omitted for brevity) |
| GET | /skills/:id/versions/:version | agent+ | Get specific version with full prompt_text |
| POST | /skills/import | user | Bulk import from array of skill objects (create-or-update with idempotency) |
| POST | /skill_results | orchestrator | Record a skill result linking verification to skill version |
| GET | /skills/:id/stats | user+ | Aggregate performance stats across versions |
| GET | /skills/:id/versions/:version/results | user+ | List individual results for a version |

---

## 7. CLI Specification

The CLI is an escript binary named `loopctl`. It communicates with the loopctl server via the REST API.

### 7.1 Configuration

Stored at `~/.loopctl/config.json`:

```json
{
  "server": "https://loopctl.local:4000",
  "api_key": "lc_xxxxxxxxxxxx",
  "format": "json"
}
```

Environment variable overrides: `LOOPCTL_SERVER`, `LOOPCTL_API_KEY`, `LOOPCTL_FORMAT`.

### 7.2 Commands

#### Auth & Config
```bash
loopctl auth login --server <url> --key <api_key>    # Configure credentials
loopctl auth whoami                                   # Show current tenant, role, key prefix
loopctl config set <key> <value>                      # Set config value
loopctl config get <key>                              # Get config value
loopctl config show                                   # Show all config
```

#### Tenant Management
```bash
loopctl tenant register --name <name> --email <email>  # Self-service signup, returns API key
loopctl tenant info                                     # Current tenant profile
loopctl tenant update --setting <key>=<value>           # Update tenant settings
```

#### API Keys
```bash
loopctl keys create --name <name> --role <role>        # Create API key
loopctl keys list                                       # List API keys
loopctl keys revoke <key_id>                            # Revoke API key
loopctl keys rotate <key_id>                            # Rotate API key
```

#### Projects
```bash
loopctl project create <name> --repo <url>             # Create project
loopctl project list                                    # List projects
loopctl project info <project>                          # Project detail
loopctl project archive <project>                       # Archive project
loopctl import <path> --project <project>               # Import user stories from JSON
loopctl export --project <project>                      # Export project to JSON
```

#### Progress & Status
```bash
loopctl status --project <project>                      # Project-wide progress summary
loopctl status --epic <epic_number>                     # Epic progress
loopctl status <story_number>                           # Story detail
loopctl next --project <project>                        # Ready stories (deps met, unassigned)
loopctl blocked --project <project>                     # Blocked stories
```

#### Agent Operations (role: agent)
```bash
loopctl agent register --name <name> --type <type>     # Self-register
loopctl contract <story_number>                         # Read & acknowledge story ACs
loopctl claim <story_number>                            # Claim a story (requires contracted)
loopctl start <story_number>                            # Mark as implementing
loopctl report <story_number> --artifact <json>         # Report done + artifact
loopctl unclaim <story_number>                          # Release assignment
```

#### Orchestrator Operations (role: orchestrator)
```bash
loopctl verify <story_number> --result <pass|fail|partial> --summary <text>    # Verify story
loopctl reject <story_number> --reason <text>                                   # Reject story
loopctl pending --project <project>                                             # Stories reported_done but unverified
loopctl state save --project <project> --data <json>                            # Checkpoint state
loopctl state load --project <project>                                          # Restore state
```

#### Audit & History
```bash
loopctl history <story_number>                          # Full audit trail for story
loopctl audit --project <project> --since <date>        # Query audit log
loopctl changes --project <project> --since <timestamp> # Change feed
```

#### Webhooks
```bash
loopctl webhook create --url <url> --events <list>     # Create webhook
loopctl webhook list                                    # List webhooks
loopctl webhook delete <id>                             # Delete webhook
loopctl webhook test <id>                               # Send test event
```

#### Skills
```bash
loopctl skill list                                    # List all skills
loopctl skill get <name>                              # Show current version prompt
loopctl skill get <name> --version <N>                # Show specific version
loopctl skill create --name <name> --file <path>      # Create from file
loopctl skill update <name> --file <path>             # New version from file
loopctl skill stats <name>                            # Performance stats by version
loopctl skill history <name>                          # Version history
loopctl skill import <directory> --project <project>  # Bulk import directory of SKILL.md files
loopctl skill archive <name>                          # Archive skill
```

#### Superadmin
```bash
loopctl admin tenants                                   # List all tenants
loopctl admin tenant <id>                               # Tenant detail
loopctl admin suspend <tenant_id>                       # Suspend tenant
loopctl admin activate <tenant_id>                      # Activate tenant
loopctl admin stats                                     # System-wide stats
loopctl admin impersonate <tenant_id> -- <command>      # Run any command as tenant
```

### 7.3 Output Formats

- `--format json` (default) — machine-readable JSON, optimized for agent consumption
- `--format human` — table/text output for human readability
- `--format csv` — for data export

Agents receive JSON by default. Humans can override with `loopctl config set format human`.

---

## 8. Import/Export Format

loopctl supports bi-directional import/export of user stories. The canonical format is JSON, compatible with existing `docs/user_stories/` directory structures.

### 8.1 Import

`POST /api/v1/projects/:id/import` accepts a JSON payload containing epics, stories, and dependencies:

```json
{
  "epics": [
    {
      "number": 1,
      "title": "Foundation & Multi-Tenant",
      "phase": "p0_foundation",
      "position": 1,
      "depends_on_epics": [],
      "stories": [
        {
          "number": "1.1",
          "title": "Base Schema & Multi-Tenant Foundation",
          "description": "...",
          "acceptance_criteria": [...],
          "estimated_hours": 4,
          "depends_on_stories": []
        }
      ]
    }
  ]
}
```

The CLI equivalent reads from a directory of JSON files:

```bash
loopctl import ./docs/user_stories/ --project freight-pilot
```

The CLI recursively reads `epic_*/us_*.json` files and assembles the import payload.

### 8.2 Export

`GET /api/v1/projects/:id/export` returns the same JSON structure, enabling round-trip fidelity.

```bash
loopctl export --project freight-pilot > project.json
loopctl export --project freight-pilot --dir ./docs/user_stories/  # Write to directory structure
```

---

## 9. CI/CD

### 9.1 GitHub Actions Pipeline

Following the open_brain pattern:

| Job | Contents | Runs On |
|-----|----------|---------|
| **lint** | `mix format --check-formatted`, `mix deps.unlock --check-unused`, `mix credo --strict` | ubuntu-latest |
| **test** | `mix compile --warnings-as-errors`, `mix test` (with PostgreSQL service) | ubuntu-latest |
| **security** | `mix sobelow --config` | ubuntu-latest |
| **dialyzer** | `mix dialyzer` (with PLT caching) | ubuntu-latest |
| **deploy** | Run deploy script on beelink (only on push to master, after all checks pass) | self-hosted |

### 9.2 Deployment

- **Initial:** beelink (192.168.86.55) via self-hosted GitHub Actions runner
- **Future:** Fly.io for public hosting at loopctl.com
- Deploy script: pull latest, compile release, run migrations, restart service
- Zero-downtime deploys via Phoenix release hot-code loading or rolling restart

---

## 10. Security Considerations

### 10.1 API Key Security
- Keys are SHA-256 hashed before storage; raw key shown only once at creation
- Key prefix (first 8 chars) stored for identification without exposing the key
- Keys can have expiration dates
- Revoked keys are soft-deleted (audit trail preserved)
- Rate limiting per key to prevent abuse

### 10.2 Multi-Tenant Isolation
- PostgreSQL RLS policies enforce tenant isolation at the database level
- Application-level `tenant_id` scoping as defense in depth
- Superadmin impersonation logged in audit trail
- No cross-tenant data leakage in error messages or query results

### 10.3 Webhook Security
- Signing secrets encrypted at rest (Cloak AES-256-GCM)
- HMAC-SHA256 signature on every webhook delivery (X-Signature-256 header)
- Auto-disable after N consecutive failures to prevent abuse of dead endpoints
- Payload size limits

### 10.4 Input Validation
- All inputs validated at the API boundary
- JSON schema validation for import payloads
- String length limits on all text fields
- Rejection of unknown fields (strict parsing)

---

## 11. Future Considerations

These features are explicitly out of scope for v1 but the architecture should not prevent their implementation:

### 11.1 Notification System
- Email notifications for stalled stories, completed epics, failed verifications
- Integration points: tenant settings for notification preferences, webhook events as triggers
- **Architecture enabler:** Oban queues for async delivery, tenant settings for preferences

### 11.2 Billing & Plans
- Tenant plans with feature/quota tiers (free, pro, enterprise)
- Usage tracking (API calls, stories, agents)
- **Architecture enabler:** tenant settings with plan-based defaults, usage counters in tenant record, rate limiting per plan

### 11.3 Web UI
- Dashboard for project status, agent activity, verification results
- **Architecture enabler:** Phoenix LiveView can be added to the existing app, API already serves all needed data

### 11.4 Fly.io Deployment
- Public hosting at loopctl.com
- **Architecture enabler:** Dockerfile, fly.toml, release configuration from day one

### 11.5 Integration Plugins
- GitHub: auto-create PRs from verified epics, link stories to commits
- Linear/Jira: two-way sync of story status
- Slack: notifications channel
- **Architecture enabler:** webhook system provides the event stream; plugins would be separate Oban workers that consume events and call external APIs

### 11.6 Automated Skill Optimization
- Autoresearch-style generate-evaluate-mutate optimization loop using the performance data collected by skill_results
- Given a skill and its historical performance metrics (false positive rate, findings accuracy, iteration count), automatically generate prompt variants, evaluate them against a test corpus, and select the best-performing version
- **Architecture enabler:** skill_versions stores prompt snapshots with immutable history; skill_results links every verification to the exact prompt version that produced it, providing the training data needed for automated optimization

---

## 12. Use Cases

### UC-1: Tenant Self-Service Registration

**Actor:** Human developer or automation script
**Precondition:** None (public endpoint)

1. POST `/api/v1/tenants/register` with `{name, email, slug}`
2. Server creates tenant with default settings
3. Server creates first API key with role=user
4. Server returns tenant record + raw API key (only time visible)
5. Actor stores API key in `~/.loopctl/config.json` or environment variable

**Postcondition:** Tenant exists, active, with one user API key.

### UC-2: Import Project from User Story JSON

**Actor:** Human developer (role: user)
**Precondition:** Authenticated, project created

1. User runs `loopctl import ./docs/user_stories/ --project freight-pilot`
2. CLI reads `epic_*/us_*.json` files, assembles import payload
3. CLI sends POST `/api/v1/projects/:id/import`
4. Server validates JSON structure
5. Server creates epics, stories, dependencies in a single transaction
6. Server returns summary: N epics, M stories, K dependencies created
7. If webhooks configured, `project.imported` event fires

**Postcondition:** All epics and stories exist with `agent_status=pending`, `verified_status=unverified`.

### UC-3: Agent Self-Registration

**Actor:** AI implementation agent (role: agent key provided by tenant admin)
**Precondition:** Has an API key with role=agent

1. Agent calls POST `/api/v1/agents/register` with `{name: "worker-1", agent_type: "implementer"}`
2. Server creates agent record, links to tenant
3. Server returns agent record with ID
4. Agent stores its agent_id for future requests

**Postcondition:** Agent exists in registry, status=active.

### UC-4: Orchestrator Queries for Next Assignable Work

**Actor:** Orchestrator agent (role: orchestrator)
**Precondition:** Authenticated, project has stories

1. Orchestrator calls GET `/api/v1/stories/ready?project_id=<id>`
2. Server returns stories where:
   - All `story_dependencies` have `verified_status=verified`
   - All parent `epic_dependencies` have all stories verified
   - `agent_status=pending`
3. Stories are ordered by: epic position, story number
4. Orchestrator selects stories to assign (up to its configured parallelism limit)

**Postcondition:** Orchestrator has a list of assignable stories.

### UC-5: Agent Claims and Implements a Story

**Actor:** AI implementation agent (role: agent)
**Precondition:** Authenticated, registered, story is ready

1. Agent calls POST `/api/v1/stories/:id/claim`
2. Server sets `agent_status=assigned`, `assigned_agent_id`, `assigned_at`
3. Server records audit log entry
4. Agent calls POST `/api/v1/stories/:id/start`
5. Server sets `agent_status=implementing`
6. Agent implements the story (outside loopctl — this is the coding work)
7. Agent calls POST `/api/v1/stories/:id/report` with optional artifact manifest
8. Server sets `agent_status=reported_done`, `reported_done_at`
9. If webhooks configured, `story.status_changed` fires at each transition

**Postcondition:** Story is `agent_status=reported_done`, `verified_status=unverified`.

### UC-6: Orchestrator Verifies a Completed Story

**Actor:** Orchestrator agent (role: orchestrator)
**Precondition:** Story is `agent_status=reported_done`

1. Orchestrator polls GET `/api/v1/changes?since=<last_poll>&project_id=<id>`
2. Orchestrator sees story status changed to `reported_done`
3. Orchestrator performs independent verification (outside loopctl — runs enhanced review, checks artifacts)
4. **If pass:** POST `/api/v1/stories/:id/verify` with `{result: "pass", summary: "...", findings: [...]}`
5. **If fail:** POST `/api/v1/stories/:id/reject` with `{reason: "No LiveView tests", findings: [...]}`
6. On rejection, server auto-resets `agent_status` to `pending`
7. Verification result recorded in `verification_results` table
8. Audit log records the transition

**Postcondition (pass):** Story `verified_status=verified`. Dependent stories may now become ready.
**Postcondition (fail):** Story `verified_status=rejected`, `agent_status=pending`. Story re-enters the queue.

### UC-7: Orchestrator Checkpoints and Recovers State

**Actor:** Orchestrator agent (role: orchestrator)
**Precondition:** Orchestrator is managing a project

1. Periodically, orchestrator saves state:
   PUT `/api/v1/orchestrator/state/:project_id` with `{state_key: "main", state_data: {...}, version: N}`
2. State includes: current phase, active assignments, last poll timestamp, plan decisions
3. If orchestrator session crashes and restarts:
   GET `/api/v1/orchestrator/state/:project_id?state_key=main`
4. Orchestrator resumes from checkpointed state
5. Orchestrator re-polls changes since last checkpoint to catch up

**Postcondition:** Orchestrator resumes without re-doing completed work.

### UC-8: Superadmin Impersonation

**Actor:** Superadmin
**Precondition:** Has superadmin API key

1. Superadmin sends any API request with `X-Impersonate-Tenant: <tenant_id>` header
2. Server validates superadmin key
3. Server sets RLS context to impersonated tenant
4. Request executes as if it were the impersonated tenant
5. Audit log records the action with `actor_type=superadmin` and the impersonation context

**Postcondition:** Action completed on behalf of tenant. Audit trail shows superadmin impersonation.

### UC-9: Epic Completion Flow

**Actor:** System (triggered by story verification)
**Precondition:** All stories in an epic reach `verified_status=verified`

1. Orchestrator verifies the last story in an epic
2. Server detects all stories in epic are verified
3. Server emits `epic.completed` webhook event
4. Orchestrator's next poll sees the epic as complete
5. Orchestrator checks epic dependencies — dependent epics may now have stories become ready

**Postcondition:** Epic is complete. Downstream epics are unblocked.

### UC-10: Bulk Import with Dependency Resolution

**Actor:** Human developer (role: user)
**Precondition:** Project exists, user has JSON story files

1. User runs `loopctl import ./docs/user_stories/ --project my-project`
2. CLI reads all `epic_*/us_*.json` files
3. CLI resolves cross-references: story "1.1" depends on story "14.1" (different epic)
4. CLI builds dependency graph and validates no cycles
5. CLI sends POST `/api/v1/projects/:id/import`
6. Server creates all entities in a single transaction
7. If cycle detected, entire import fails with clear error message

**Postcondition:** Full project imported with all dependencies correctly wired.

### UC-11: Webhook-Driven Orchestrator

**Actor:** Orchestrator agent (role: orchestrator) using webhooks instead of polling

1. Tenant configures webhook: POST `/api/v1/webhooks` with URL and events
2. When agent reports a story done, server sends `story.status_changed` event to webhook URL
3. Orchestrator receives webhook, verifies HMAC signature
4. Orchestrator performs verification
5. Orchestrator posts result back via API

**Postcondition:** Orchestrator is event-driven instead of polling. Lower latency, same trust model.

### UC-12: Multi-Agent Parallel Implementation

**Actor:** Orchestrator assigning work to multiple agents
**Precondition:** Multiple ready stories, multiple registered agents

1. Orchestrator queries GET `/api/v1/stories/ready?project_id=<id>`
2. Server returns N ready stories
3. Orchestrator assigns up to M stories (its configured parallelism limit)
4. Each agent claims its assigned story
5. Agents work in parallel (in separate worktrees/branches)
6. As agents report done, orchestrator picks up changes via polling/webhooks
7. Orchestrator verifies each independently
8. New stories may become ready as dependencies are verified

**Postcondition:** Multiple stories progressing in parallel with independent verification.

### UC-13: Export and Re-Import (Round Trip)

**Actor:** Human developer
**Precondition:** Project exists with stories

1. Export: `loopctl export --project my-project > project.json`
2. Modify JSON (add stories, adjust acceptance criteria)
3. Re-import: `loopctl import project.json --project my-project --merge`
4. Server merges: creates new stories, updates existing ones (matched by number), preserves status on unchanged stories
5. Deleted stories in JSON are flagged but not auto-deleted (safety)

**Postcondition:** Project updated with changes from JSON while preserving existing progress.

### UC-14: Agent Artifact Reporting with Commit Diff

**Actor:** Implementation agent (role: agent)
**Precondition:** Agent has completed work, committed code

1. Agent calls POST `/api/v1/stories/:id/artifacts` with:
   ```json
   {
     "artifact_type": "commit_diff",
     "path": "abc123..def456",
     "exists": true,
     "details": {
       "commit_sha": "def456",
       "branch": "epic/epic_2_load_management",
       "files_changed": ["lib/my_app/loads.ex", "lib/my_app_web/live/load_live.ex", ...],
       "insertions": 450,
       "deletions": 12
     }
   }
   ```
2. Agent can submit multiple artifact reports (one per commit, or categorized by type)
3. Server stores all reports, links to story
4. Orchestrator later reads artifacts as part of verification

**Postcondition:** Story has artifact reports that orchestrator can cross-reference during verification.

---

## 13. Non-Functional Requirements

### 13.1 Performance
- API response time: <100ms for single-entity CRUD, <500ms for graph queries
- Support 100+ concurrent agent connections per tenant
- Change feed query: <200ms for typical polling window (last 60 seconds)

### 13.2 Reliability
- Database transactions for all multi-entity mutations
- Webhook delivery: at-least-once with exponential backoff
- Orchestrator state: optimistic locking prevents concurrent corruption
- Zero data loss on application restart

### 13.3 Observability
- Structured logging (JSON) with tenant_id, request_id, actor context
- Telemetry events for key operations (API calls, webhook deliveries, status transitions)
- Health check endpoint: GET `/health`

### 13.4 Scalability
- Single-node deployment sufficient for initial use
- Stateless API layer (no in-memory session state) enables horizontal scaling
- PostgreSQL as the single source of truth

---

## 14. Token Efficiency and Cost Intelligence

### Overview

loopctl tracks token consumption at the story level to provide cost accountability for multi-agent AI development loops. Agents report token usage when completing stories; the system aggregates this into per-agent efficiency rankings, per-project cost summaries, and anomaly alerts.

The guiding principle is the same as the trust model: agents cannot self-verify their work, and they cannot hide their cost. Token budgets and anomaly detection are enforced at the API layer.

### 14.1 Token Usage Reporting

Agents include token counts when reporting a story done. The `POST /stories/:id/report` endpoint accepts:

```json
{
  "token_usage": {
    "input_tokens": 48200,
    "output_tokens": 12400,
    "model": "claude-sonnet-4-5"
  }
}
```

Token records are stored in `token_usage` rows linked to the story and the agent. Multiple reports per story are allowed (pre-report, final report). The orchestrator reads the most recent verified record.

### 14.2 Cost Summary API

`GET /api/v1/projects/:id/token-usage` returns a project-wide cost summary:

- Total input/output tokens per agent
- Tokens-per-story ratio per agent (efficiency ranking)
- Model mix breakdown (e.g., sonnet vs. opus distribution)
- Cost estimates based on configured per-token pricing
- Sprint-level and all-time views via `?period=sprint` or `?period=all`

### 14.3 Token Budgets

Configured via `POST /api/v1/projects/:id/token-budgets`:

```json
{
  "scope_type": "per_story",
  "token_limit": 200000,
  "warning_threshold": 0.80,
  "enforcement": "warn"
}
```

Supported `scope_type` values: `per_story`, `per_agent`, `per_epic`, `per_project`.
Supported `enforcement` values: `warn` (flag only), `block` (reject story report if exceeded).

When a story report is submitted and the budget is exceeded with `enforcement: block`, the API returns `429 token_budget_exceeded` with the overage details.

### 14.4 Anomaly Detection

The system computes a rolling per-project baseline (median tokens-per-story) and flags reports that deviate beyond a configurable multiplier (default: 3x). Anomalies are visible via:

- `GET /api/v1/projects/:id/cost-anomalies` — list all open anomalies
- Webhook event `token.anomaly_detected` — real-time push on new anomaly

### 14.5 Skill Cost Regression Detection

When a skill version changes and subsequent stories using that skill show a significant increase in token consumption (default threshold: 1.5x above the prior version's median), a `skill.cost_regression_detected` event is emitted. This allows orchestrators to roll back expensive prompt updates before they compound across a full sprint.

Tracked via `GET /api/v1/skills/:id/cost-regression`.

### 14.6 CLI Commands

```bash
loopctl token-usage --project my-app           # Project summary
loopctl token-usage --project my-app --agent worker-2  # Single agent
loopctl cost-anomalies --project my-app        # Open anomalies
loopctl budget set --project my-app --scope per_story --limit 200000
```

---

## Appendix A: Glossary

| Term | Definition |
|------|-----------|
| **Agent** | An AI coding agent that implements features (e.g., Claude Code sub-agent) |
| **Orchestrator** | An AI agent that coordinates work, verifies deliverables, and manages the development loop (e.g., a Claude Code skill) |
| **Skill** | A versioned prompt or instruction set used by the orchestrator or review agents. Skills are stored in loopctl with version history and performance tracking. |
| **Story** | The atomic unit of work, typically a user story with acceptance criteria |
| **Epic** | A group of related stories |
| **Artifact** | A file, commit, or code element produced by implementing a story |
| **Verification** | The orchestrator's independent assessment of whether a story's deliverables meet specifications |
| **Stall** | When an assigned story shows no activity beyond the configured threshold |
| **Change feed** | A queryable stream of state changes, used by orchestrators to detect new completions |
| **Tenant** | An organizational unit; all data is isolated per tenant |
| **Loop** | The development cycle: plan → assign → implement → report → verify → (accept or reject and retry) |
