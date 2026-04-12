# loopctl

[![CI](https://github.com/mkreyman/loopctl/actions/workflows/ci.yml/badge.svg)](https://github.com/mkreyman/loopctl/actions/workflows/ci.yml)
![Elixir](https://img.shields.io/badge/Elixir-1.18-purple)
![Phoenix](https://img.shields.io/badge/Phoenix-1.8-orange)
![License](https://img.shields.io/badge/License-MIT-green)

An open-source, agent-native project state store for AI development loops.

loopctl provides a multi-tenant REST API and CLI for AI coding agents and orchestrators to track project work breakdown, report progress, verify deliverables, and maintain audit trails. It solves the problem of AI agents fabricating results by separating self-reported progress from independently verified progress.

**Website:** [loopctl.com](https://loopctl.com)

## The Problem

When AI coding agents implement large projects (25+ epics, 185+ stories), there is no reliable way to:

- Track what work has actually been completed vs. what agents *claim* is done
- Independently verify that deliverables match specifications
- Coordinate multiple implementation agents working in parallel
- Resume orchestration after session interruptions
- Maintain an audit trail of who did what and when

In practice, implementing agents fabricate review results, skip UI implementation while claiming backend is "complete," and self-report success without producing the required artifacts.

## The Solution

loopctl is a **dumb state store** with a **two-tier trust model**:

- **Implementation agents** write their own status (`agent_status`: pending -> contracted -> assigned -> implementing -> reported_done)
- **An independent orchestrator** reads those updates, performs verification, and writes its findings (`verified_status`: unverified -> verified -> rejected)
- It is **structurally impossible** for implementing agents to mark their own work as verified

loopctl does not make decisions, execute code, or run tests. It stores state, enforces access control, and serves data.

## Key Features

- **Two-tier trust model** -- agent_status and verified_status are written by different roles via `exact_role` enforcement
- **Multi-tenant** with PostgreSQL Row Level Security -- every tenant's data is fully isolated
- **Sprint contracts** -- agents must acknowledge acceptance criteria before claiming stories
- **Dependency graph** -- epic and story dependencies with cycle detection, ready/blocked queries
- **Webhook events** -- real-time notifications on status changes, signed with HMAC-SHA256
- **Audit trail** -- immutable, append-only log of every mutation with partitioning and 90-day retention
- **Skill versioning** -- store, version, and track performance of orchestrator prompts
- **Import/export** -- bulk import user stories from JSON, export for round-trip fidelity
- **CLI** -- escript binary for all operations (`loopctl status`, `loopctl claim`, `loopctl verify`)
- **Token cost intelligence** -- agents report token usage per story; per-agent efficiency rankings, configurable budgets, and anomaly detection prevent runaway costs across long sprints
- **OpenAPI 3.0** -- self-documenting API with Swagger UI for agent discovery

## Concepts

| Term | Definition |
|------|-----------|
| **Tenant** | An organization. All data is isolated per tenant via PostgreSQL RLS. |
| **Project** | A codebase being tracked (e.g., a GitHub repo). |
| **Epic** | A group of related stories within a project. |
| **Story** | The atomic unit of work with acceptance criteria. |
| **Agent** | An AI coding agent that implements features (implementer) or coordinates work (orchestrator). |
| **Orchestrator** | An AI agent that assigns work, verifies deliverables, and manages the development loop. |
| **Two-tier trust** | Implementing agents write `agent_status`; orchestrators write `verified_status`. Neither can write the other. |
| **Contract** | An agent acknowledges a story's acceptance criteria before claiming it. |
| **Skill** | A versioned prompt/instruction set used by orchestrators, with performance tracking. |
| **Token Budget** | A configurable token-consumption limit scoped to a story, agent, epic, or project. Exceeding the limit can warn or block story reports. |
| **Cost Summary** | An aggregated view of token usage per agent, with efficiency rankings and model mix breakdown. |
| **Cost Anomaly** | A story whose token consumption deviates beyond a configurable multiplier from the project baseline, flagged automatically. |

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Elixir 1.18 / Erlang OTP 27 |
| Framework | Phoenix 1.8 (API-only) |
| Database | PostgreSQL 16 with RLS |
| Background Jobs | Oban |
| HTTP Client | Req |
| Encryption | Cloak (AES-256-GCM) |
| CLI | Escript |
| Deployment | Docker Compose (PostgreSQL + App + Nginx) |

## Quick Start

### Local Development

```bash
# Prerequisites: Elixir 1.18+, PostgreSQL 16+

git clone https://github.com/mkreyman/loopctl.git
cd loopctl

# 1. Create the loopctl_app role (needed for RLS in tests)
#    The dev server uses the postgres superuser, but tests switch to
#    the loopctl_app role via SET LOCAL ROLE to enforce RLS policies.
psql -U postgres -c "CREATE ROLE loopctl_app LOGIN PASSWORD 'loopctl_app_pass';"
psql -U postgres -c "GRANT ALL ON DATABASE loopctl_dev TO loopctl_app;"

# 2. Setup and run
#    mix setup installs deps, creates the database, and runs migrations.
#    A default Cloak encryption key is configured in config.exs for dev.
mix setup
mix phx.server       # Start server at localhost:4000

# Verify it's working
curl http://localhost:4000/health
# Should return: {"status":"ok",...}

# Token efficiency commands (after registering a tenant + project)
loopctl token-usage --project my-app           # Project cost summary
loopctl cost-anomalies --project my-app        # Open anomalies
loopctl budget set --project my-app --scope per_story --limit 200000
```

> **Note:** The `CLOAK_KEY` and `SECRET_KEY_BASE` environment variables are only required for production/Docker deployments. Dev uses defaults from `config/dev.exs` and `config/config.exs`.

### Docker Deployment

```bash
# Prerequisites: Docker, Docker Compose

cp .env.example .env
# Edit .env with your secrets (see "Generate Secrets" below)

# Generate TLS certificates for nginx (deploy/certs/ must exist)
mkdir -p deploy/certs
openssl req -x509 -newkey rsa:4096 -keyout deploy/certs/selfsigned.key \
  -out deploy/certs/selfsigned.crt -days 365 -nodes \
  -subj "/CN=loopctl.local"

docker compose build
docker compose up -d
docker compose exec -T app /app/bin/migrate

# Verify it's working
curl -sk https://localhost:8443/health
# Should return: {"status":"ok",...}
```

### Generate Secrets

```bash
# SECRET_KEY_BASE
mix phx.gen.secret

# CLOAK_KEY (32 bytes, base64)
elixir -e ':crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()'
```

> **Ports:** Local development runs on `http://localhost:4000`. Docker deployment uses `https://localhost:8443` (nginx TLS proxy). All examples below use the local dev URL.

## API Overview

Once running, the API is self-documenting:

- `GET /` -- Redirects to `/api/v1/`
- `GET /api/v1/` -- Discovery endpoint with links
- `GET /api/v1/openapi` -- Full OpenAPI 3.0 specification (machine-readable)
- `GET /swaggerui` -- Interactive Swagger UI (human-readable)
- `GET /health` -- Health check

### Authentication Flow

loopctl uses role-based API keys. Each role has specific permissions in the two-tier trust model.

1. **Register as a tenant** — visit `https://loopctl.com/signup` (requires a hardware authenticator: YubiKey, Touch ID, or Windows Hello). CLI-based registration is no longer supported.

2. **Create role-specific keys** (using your user key):
   ```bash
   # Create an agent key (needed to register agents)
   curl -X POST http://localhost:4000/api/v1/api_keys \
     -H "Authorization: Bearer lc_user_key" \
     -H "Content-Type: application/json" \
     -d '{"name": "agent-bootstrap", "role": "agent"}'

   # Register an orchestrator agent
   curl -X POST http://localhost:4000/api/v1/agents/register \
     -H "Authorization: Bearer lc_agent_bootstrap_key" \
     -H "Content-Type: application/json" \
     -d '{"name": "orchestrator-main", "agent_type": "orchestrator"}'
   # Note the agent ID from the response

   # Create the orchestrator key linked to the agent
   curl -X POST http://localhost:4000/api/v1/api_keys \
     -H "Authorization: Bearer lc_user_key" \
     -H "Content-Type: application/json" \
     -d '{"name": "orchestrator-main", "role": "orchestrator", "agent_id": "<agent_id>"}'

   # Create an implementer agent key
   curl -X POST http://localhost:4000/api/v1/api_keys \
     -H "Authorization: Bearer lc_user_key" \
     -H "Content-Type: application/json" \
     -d '{"name": "worker-1", "role": "agent"}'
   ```

3. **Register your implementer agent** (using the agent key):
   ```bash
   curl -X POST http://localhost:4000/api/v1/agents/register \
     -H "Authorization: Bearer lc_agent_key" \
     -H "Content-Type: application/json" \
     -d '{"name": "worker-1", "agent_type": "implementer"}'
   ```

> **Note:** Each agent-role API key can register exactly ONE agent (one-to-one binding). Once an agent key has registered an agent, calling `/agents/register` again with the same key returns 409. To register multiple agents, create separate agent keys for each:
> ```bash
> # Create keys for 2 implementation agents + 1 orchestrator bootstrap
> curl -X POST .../api_keys -d '{"name": "worker-1", "role": "agent"}'
> curl -X POST .../api_keys -d '{"name": "worker-2", "role": "agent"}'
> curl -X POST .../api_keys -d '{"name": "orch-bootstrap", "role": "agent"}'
> ```

Now the agent key can contract, claim, start, and report stories. The orchestrator key (linked to its agent) can verify and reject stories.

### Typical Agent Workflow

The chain-of-custody rule: nobody marks their own work as done. The implementer requests review; a different agent confirms it.

```
Setup:
1. Register tenant        Visit /signup (WebAuthn required)
2. Create project         POST /api/v1/projects
3. Import stories         POST /api/v1/projects/:id/import
4. Register agent         POST /api/v1/agents/register

Per story (implementer):
5. Get ready stories      GET  /api/v1/stories/ready?project_id=...
6. Contract story         POST /api/v1/stories/:id/contract
7. Claim story            POST /api/v1/stories/:id/claim
8. Start implementing     POST /api/v1/stories/:id/start-work  (or /start)
9. Request review         POST /api/v1/stories/:id/request-review
   ↳ fires story.review_requested webhook
   ↳ implementer's role ENDS here

Per story (reviewer — must be a DIFFERENT agent):
10. Confirm implementation POST /api/v1/stories/:id/report  (409 if caller == implementer)
11. Complete review        POST /api/v1/stories/:id/review-complete  (409 if caller == implementer)
    ↳ fires story.review_completed webhook

Per story (orchestrator):
12. Verify or reject       POST /api/v1/stories/:id/verify  OR  /reject
    ↳ verify returns 409 if orchestrator == implementer
```

### Roles

| Role | Can Do |
|------|--------|
| `superadmin` | Everything. Cross-tenant via impersonation. |
| `user` | Manage tenant settings, API keys, projects, import/export. |
| `orchestrator` | Verify/reject stories. Write orchestrator state. Force-unclaim. |
| `agent` | Contract, claim, start, report stories. Submit artifacts. |

> **Role design note:** The `user` role is for tenant administration -- managing settings, API keys, and projects. It does not participate in the development trust model. The `orchestrator` and `agent` roles manage the development loop. This separation is by design: tenant admins provision infrastructure while the trust model governs the implementation/verification cycle.

> **Superadmin keys** are created via the database or by a privileged script -- they cannot be created through the API since they require `tenant_id=NULL`.

### Two-Tier Trust Model and Chain-of-Custody Enforcement

The two-tier trust model governs **who can write which field**. The chain-of-custody principle governs **who can perform each handoff action**: nobody marks their own work as done.

#### Identity Gates

Three endpoints enforce caller identity at the API level. If the caller is the assigned agent, the request is rejected with 409:

| Endpoint | Blocked response | Meaning |
|----------|-----------------|---------|
| `POST /stories/:id/report` | `409 self_report_blocked` | The implementer cannot mark their own work as done — a different agent (reviewer) must call this |
| `POST /stories/:id/review-complete` | `409 self_review_blocked` | The reviewer cannot declare their own review complete if they were the implementer |
| `POST /stories/:id/verify` | `409 self_verify_blocked` | The orchestrator cannot verify a story they implemented |

The field `stories.reported_by_agent_id` tracks which agent confirmed the implementation (i.e., called `/report`). This must differ from the assigned implementer.

#### Request-Review Endpoint

When an implementer finishes work, they do **not** call `/report` directly. Instead, they signal readiness:

```bash
POST /stories/:id/request-review
```

This transitions the story to a "review requested" state without advancing `agent_status` to `reported_done`. It fires a `story.review_requested` webhook. A different agent (the reviewer) then calls `/report` to confirm the implementation, followed by `/review-complete` to close the review. Only then can the orchestrator call `/verify`.

#### Endpoint Reference

```
Agent endpoints (exact_role: agent):
  POST /stories/:id/contract
  POST /stories/:id/claim
  POST /stories/:id/start             (alias: /start-work)
  POST /stories/:id/request-review    (NEW — signals readiness, does NOT mark done)

Reviewer endpoints (different agent from implementer):
  POST /stories/:id/report            (alias: /report-done — blocked if caller == assigned_agent_id)
  POST /stories/:id/review-complete   (blocked if caller == assigned_agent_id)

Orchestrator endpoints (exact_role: orchestrator):
  POST /stories/:id/verify            (requires review_type and summary — blocked if caller == assigned_agent_id)
  POST /stories/:id/reject
  POST /stories/:id/force-unclaim
  POST /stories/bulk/mark-complete    (mark pre-existing stories complete in one call)
  POST /epics/:id/verify-all          (verify all reported_done stories in an epic)
```

An agent key **cannot** call verify/reject. An orchestrator key **cannot** call claim/start/request-review. This is enforced at the plug level with strict atom equality -- no role hierarchy bypass. Identity gates are an additional layer enforced regardless of role.

### Sprint Contracts

Before claiming a story, agents must **contract** it -- acknowledging they have read the acceptance criteria by echoing back the story title and AC count. This prevents agents from claiming stories they have not read:

```bash
# Agent fetches story, reads ACs, then contracts
curl -X POST http://localhost:4000/api/v1/stories/:id/contract \
  -H "Authorization: Bearer lc_agent_key" \
  -H "Content-Type: application/json" \
  -d '{"story_title": "Implement user auth", "ac_count": 8}'
```

If the title or count does not match, the contract is rejected.

Orchestrators can skip contract validation for bulk operations using `skip_contract_check: true`
(orchestrator role only):

```bash
curl -X POST http://localhost:4000/api/v1/stories/:id/contract \
  -H "Authorization: Bearer lc_orch_key" \
  -H "Content-Type: application/json" \
  -d '{"skip_contract_check": true}'
```

### Listing Stories

`GET /api/v1/stories` returns stories with flexible filters. Supports up to 500 results per page
via `limit` and `offset`.

```bash
# All stories in a project
curl http://localhost:4000/api/v1/stories?project_id=<id>

# Filter by status fields
curl "http://localhost:4000/api/v1/stories?project_id=<id>&agent_status=reported_done&verified_status=unverified"

# Filter to a specific epic
curl "http://localhost:4000/api/v1/stories?project_id=<id>&epic_id=<epic_id>"

# Paginate a large project
curl "http://localhost:4000/api/v1/stories?project_id=<id>&limit=500&offset=0"
curl "http://localhost:4000/api/v1/stories?project_id=<id>&limit=500&offset=500"
```

Available query parameters: `project_id` (required), `agent_status`, `verified_status`, `epic_id`,
`limit` (max 500, default 100), `offset` (default 0).

### UI Test Runs

UI test runs track project-level, ad-hoc QA walkthroughs against a running application. They are
not tied to individual stories — a UI test run covers the whole app from a user's perspective.

UI testing is **optional**. Not all projects need it. Run a UI test pass when you want to verify
the full application works end-to-end after a batch of stories has been merged.

**Start a UI test run:**

```bash
curl -X POST http://localhost:4000/api/v1/projects/:id/ui_test_runs \
  -H "Authorization: Bearer lc_orch_key" \
  -H "Content-Type: application/json" \
  -d '{"notes": "Post-epic-37 QA pass"}'
# Returns: {"data": {"id": "<run_uuid>", "status": "running", ...}}
```

**Record findings** (one call per finding):

```bash
curl -X POST http://localhost:4000/api/v1/ui_test_runs/:id/findings \
  -H "Authorization: Bearer lc_orch_key" \
  -H "Content-Type: application/json" \
  -d '{
    "severity": "bug",
    "title": "Login form does not show error on invalid password",
    "steps": "1. Visit /login\n2. Enter wrong password\n3. Submit",
    "expected": "Error message displayed below the password field",
    "actual": "Page reloads with no feedback"
  }'
```

**Complete a UI test run:**

```bash
curl -X POST http://localhost:4000/api/v1/ui_test_runs/:id/complete \
  -H "Authorization: Bearer lc_orch_key" \
  -H "Content-Type: application/json" \
  -d '{"summary": "3 bugs found, 1 enhancement suggestion"}'
```

**List runs for a project:**

```bash
curl "http://localhost:4000/api/v1/projects/:id/ui_test_runs" \
  -H "Authorization: Bearer lc_orch_key"
```

**Get a single run with its findings:**

```bash
curl "http://localhost:4000/api/v1/ui_test_runs/:id" \
  -H "Authorization: Bearer lc_orch_key"
```

#### Finding Format

Each finding has the following fields:

| Field | Required | Description |
|-------|----------|-------------|
| `severity` | Yes | One of: `bug`, `enhancement`, `blocker` |
| `title` | Yes | Short description of the finding |
| `steps` | No | Reproduction steps |
| `expected` | No | Expected behavior |
| `actual` | No | Actual behavior observed |

---

### Bulk and Admin Endpoints

**Mark pre-existing stories as complete** in a single request. Useful when bootstrapping a project
that already has completed work:

```bash
curl -X POST http://localhost:4000/api/v1/stories/bulk/mark-complete \
  -H "Authorization: Bearer lc_orch_key" \
  -H "Content-Type: application/json" \
  -d '{
    "stories": [
      {"story_id": "<uuid>", "summary": "Pre-existing implementation", "review_type": "pre_existing"},
      {"story_id": "<uuid>", "summary": "Carried over from v1", "review_type": "pre_existing"}
    ]
  }'
```

**Verify all reported_done stories in an epic** at once (orchestrator only). Both `review_type` and
`summary` are required:

```bash
curl -X POST http://localhost:4000/api/v1/epics/:id/verify-all \
  -H "Authorization: Bearer lc_orch_key" \
  -H "Content-Type: application/json" \
  -d '{"review_type": "enhanced", "summary": "All stories reviewed and AC-compliant"}'
```

### Verify Endpoint Requirements

The verify endpoint **requires** both `review_type` and `summary`. Omitting either returns 422:

```bash
curl -X POST http://localhost:4000/api/v1/stories/:id/verify \
  -H "Authorization: Bearer lc_orch_key" \
  -H "Content-Type: application/json" \
  -d '{"result": "pass", "review_type": "enhanced", "summary": "All acceptance criteria met"}'
```

### 409 Conflict Responses

When a state transition is invalid, 409 responses include structured context:

```json
{
  "error": {
    "message": "Conflict",
    "current_state": "assigned",
    "attempted_action": "claim",
    "hints": ["Story is already claimed by another agent. Use force-unclaim to reset it."]
  }
}
```

The `current_state`, `attempted_action`, and `hints` fields are always present on 409 responses
from story transition endpoints. Read `hints` to understand the corrective action.

### Story Lifecycle

```
pending --> contracted --> assigned --> implementing --> reported_done
   ^                                                          |
   |              +-------------------------------------------+
   |              v
   |         +---------+
   |         | VERIFY   |--> verified
   |         |    or    |
   |         | REJECT   |--> rejected --> auto-reset to pending
   |         +---------+
   |
   +---- unclaim / force-unclaim (back to pending)
```

### Import JSON Format

The import endpoint accepts a structured JSON payload with epics, stories, and optional dependencies:

```bash
curl -X POST http://localhost:4000/api/v1/projects/:id/import \
  -H "Authorization: Bearer lc_user_key" \
  -H "Content-Type: application/json" \
  -d '{
    "epics": [
      {
        "number": 1,
        "title": "User Authentication",
        "description": "Auth infrastructure",
        "stories": [
          {
            "number": "1.1",
            "title": "Implement login endpoint",
            "acceptance_criteria": [
              {"criterion": "POST /login returns JWT on valid credentials"},
              {"criterion": "Invalid credentials return 401"}
            ]
          },
          {
            "number": "1.2",
            "title": "Implement logout endpoint",
            "acceptance_criteria": [
              {"criterion": "POST /logout invalidates the session"}
            ]
          }
        ]
      }
    ],
    "story_dependencies": [
      {"story": "1.1", "depends_on": "1.2"}
    ],
    "epic_dependencies": [
      {"epic": 1, "depends_on": 2}
    ]
  }'
```

Each epic requires `number` (integer) and `title` (string). Each story requires `number` (string, e.g. "1.1") and `title`. Stories are nested under their epic's `stories` array. Story dependencies use `"story"` and `"depends_on"` keys referencing story numbers. Epic dependencies use `"epic"` and `"depends_on"` keys referencing epic numbers. All dependencies are validated for cycles.

#### Importing Pre-existing Work

Stories can be imported with initial status overrides using `initial_agent_status` and
`initial_verified_status`. This allows bootstrapping projects where some or all work already exists:

```json
{
  "stories": [
    {
      "number": "1.1",
      "title": "Database schema",
      "acceptance_criteria": [{"criterion": "Migrations applied"}],
      "initial_agent_status": "reported_done",
      "initial_verified_status": "pass"
    }
  ]
}
```

Stories imported with `initial_verified_status: "pass"` are treated as already verified and will
not appear in the ready queue or block dependent stories.

### Webhook Event Types

Subscribe to real-time notifications for these event types:

| Event Type | Fired When |
|------------|------------|
| `story.status_changed` | Agent transitions story status (contract, claim, start) |
| `story.review_requested` | Implementer calls `/request-review` — signals readiness for handoff |
| `story.review_completed` | Reviewer calls `/review-complete` — review cycle is closed |
| `story.verified` | Orchestrator verifies a story |
| `story.rejected` | Orchestrator rejects a story |
| `story.auto_reset` | Rejected story auto-resets to pending |
| `story.force_unclaimed` | Orchestrator force-unclaims a story |
| `epic.completed` | All stories in an epic are verified |
| `artifact.reported` | Agent submits an artifact report |
| `agent.registered` | New agent registers |
| `project.imported` | Work breakdown imported into a project |
| `webhook.test` | Manual test ping via POST /webhooks/:id/test |

#### Webhook Payloads

Every webhook delivery is a JSON POST with the following envelope. The `data` fields vary by event type.

**`story.status_changed`** -- fired on contract, claim, start, report:

```json
{
  "event": "story.status_changed",
  "story_id": "a1b2c3d4-...",
  "project_id": "b2c3d4e5-...",
  "epic_id": "c3d4e5f6-...",
  "old_status": "pending",
  "new_status": "contracted",
  "agent_id": "d4e5f6a7-...",
  "timestamp": "2026-03-27T12:00:00Z"
}
```

**`story.verified`** -- fired when orchestrator verifies a story:

```json
{
  "event": "story.verified",
  "story_id": "a1b2c3d4-...",
  "project_id": "b2c3d4e5-...",
  "epic_id": "c3d4e5f6-...",
  "orchestrator_agent_id": "e5f6a7b8-...",
  "summary": "All acceptance criteria met",
  "timestamp": "2026-03-27T14:00:00Z"
}
```

**`story.rejected`** -- fired when orchestrator rejects a story:

```json
{
  "event": "story.rejected",
  "story_id": "a1b2c3d4-...",
  "project_id": "b2c3d4e5-...",
  "epic_id": "c3d4e5f6-...",
  "orchestrator_agent_id": "e5f6a7b8-...",
  "reason": "Missing test coverage for edge cases",
  "findings": {"missing_tests": ["empty input handling", "error boundary"]},
  "timestamp": "2026-03-27T15:00:00Z"
}
```

The `findings` field is a map (object) matching whatever the orchestrator passed in the reject request body. It defaults to `{}` if omitted.

Payloads are signed with HMAC-SHA256 using the webhook's secret. Verify the `X-Loopctl-Signature` header to authenticate delivery.

#### Verifying Webhook Signatures

```elixir
# Elixir
expected = :crypto.mac(:hmac, :sha256, signing_secret, raw_body)
           |> Base.encode16(case: :lower)
signature = "sha256=" <> expected
# Compare with X-Loopctl-Signature header
```

```bash
# Bash
echo -n "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/.* /sha256=/'
```

### Rate Limiting

API requests are rate-limited per API key and per tenant:

- **Per key:** 300 requests/minute (configurable via tenant settings)
- **Per tenant:** 3x the per-key limit (aggregate across all keys)
- **Registration:** 5 requests/hour per IP address
- **Superadmin:** exempt from rate limiting

Rate limit headers are included in every authenticated response:

| Header | Description |
|--------|-------------|
| `X-RateLimit-Limit` | Requests allowed per window |
| `X-RateLimit-Remaining` | Requests remaining in current window |
| `X-RateLimit-Reset` | Unix timestamp when the window resets |

429 responses include a `Retry-After` header and `retry_after_seconds` in the JSON body:

```json
{"error": {"status": 429, "message": "Too many requests. Retry after 45 seconds.", "retry_after_seconds": 45}}
```

### Route Discovery

```
GET /api/v1/routes
```

Returns all available API endpoints with method, path, and description. Agents can call this first to discover the API without probing blindly.

### Parameter Aliasing

All list endpoints accept both `limit` and `page_size` as query params (bidirectional aliasing). Use whichever you prefer — they are interchangeable.

### Pagination

All list endpoints support page-based pagination:

- `?page=1&page_size=20` (defaults)
- Maximum `page_size`: 100 (general endpoints)
- Maximum `limit`: 500 (`GET /stories` endpoint)

Responses include metadata:

```json
{
  "data": [...],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total_count": 42,
    "total_pages": 3
  }
}
```

The change feed (`GET /api/v1/changes`) uses cursor-based pagination with `?since=<ISO8601>`. Responses include `has_more` and `next_since` for continuation.

### Error Responses

All errors follow a consistent envelope format:

```json
{"error": {"message": "Not found", "status": 404}}
```

Validation errors include field-level details:

```json
{
  "error": {
    "message": "Validation failed",
    "status": 422,
    "details": {
      "slug": ["has already been taken"],
      "email": ["can't be blank"]
    }
  }
}
```

## CLI

The CLI is an escript binary that wraps the REST API:

```bash
# Build
mix escript.build

# Configure
./loopctl auth login --server https://loopctl.local:8443 --key lc_your_key

# Use
./loopctl status --project my-project
./loopctl next --project my-project
./loopctl claim US-2.1
./loopctl verify US-2.1 --result pass --summary "All ACs met"
./loopctl skill list
./loopctl admin stats
```

Default output is JSON (agent-first). Use `--format human` for tables.

## MCP Server (for Claude Code Agents)

loopctl ships with an MCP (Model Context Protocol) server that gives Claude Code agents direct typed tool access — no curl, no bash, no JSON parsing.

### Setup

```bash
# Install dependencies
cd mcp-server && npm install

# Add to ~/.claude/mcp.json (global) or <project>/.mcp.json (per-project)
{
  "mcpServers": {
    "loopctl": {
      "command": "node",
      "args": ["/path/to/loopctl/mcp-server/index.js"],
      "env": {
        "NODE_TLS_REJECT_UNAUTHORIZED": "0",
        "LOOPCTL_SERVER": "https://192.168.86.55:8443",
        "LOOPCTL_ORCH_KEY": "lc_your_orchestrator_key",
        "LOOPCTL_AGENT_KEY": "lc_your_agent_key",
        "LOOPCTL_REVIEWER_KEY": "lc_your_reviewer_key"
      }
    }
  }
}
```

Keys must be in the `env` block — the MCP server process does not inherit the shell environment.

### Available Tools (33)

| Tool | Description | API Key Used |
|------|------------|-------------|
| `get_tenant` | Verify connectivity (current tenant info) | orchestrator |
| `list_projects` | List all projects | orchestrator |
| `create_project` | Create a new project | orchestrator |
| `get_progress` | Project progress summary (supports `include_cost`) | orchestrator |
| `import_stories` | Import epics and stories | orchestrator |
| `list_stories` | List stories with filters (supports `include_token_totals`) | orchestrator |
| `list_ready_stories` | Stories ready for work | orchestrator |
| `get_story` | Get story details | orchestrator |
| `contract_story` | Contract a story | agent |
| `claim_story` | Claim a story | agent |
| `start_story` | Start implementation | agent |
| `request_review` | Signal readiness for review | agent |
| `report_story` | Mark implementation done (supports `token_usage`) | orchestrator |
| `review_complete` | Record review completion | orchestrator |
| `verify_story` | Verify a story | orchestrator |
| `reject_story` | Reject a story | orchestrator |
| `bulk_mark_complete` | Bulk mark stories complete | orchestrator |
| `verify_all_in_epic` | Verify all in an epic | orchestrator |
| `report_token_usage` | Report token consumption for a story session | agent |
| `get_cost_summary` | Project cost summary with optional breakdown | orchestrator |
| `get_story_token_usage` | Token usage records for a story | orchestrator |
| `get_cost_anomalies` | Cost anomaly alerts | orchestrator |
| `set_token_budget` | Set token budget for a scope | orchestrator |
| `knowledge_index` | Load knowledge wiki catalog | agent |
| `knowledge_search` | Search knowledge wiki by topic | agent |
| `knowledge_get` | Get full article content by ID | agent |
| `knowledge_context` | Get relevance-ranked articles for a task query | agent |
| `knowledge_create` | Create a new knowledge article | agent |
| `knowledge_publish` | Publish a draft article | orchestrator |
| `knowledge_drafts` | List draft (unpublished) articles | orchestrator |
| `knowledge_lint` | Lint check for stale or low-coverage articles | orchestrator |
| `knowledge_export` | Export all articles as ZIP archive | orchestrator |
| `list_routes` | Discover all API endpoints | orchestrator |

Agents call tools directly: `mcp__loopctl__get_tenant()`, `mcp__loopctl__list_projects()`, `mcp__loopctl__create_project({name: "MyApp", slug: "myapp"})`. No curl or bash needed.

## Project Structure

```
lib/loopctl/
  tenants/         # Multi-tenancy
  auth/            # API keys, RBAC
  audit/           # Immutable audit log
  agents/          # Agent registry
  projects/        # Projects CRUD
  work_breakdown/  # Epics, stories, dependencies, graph queries
  progress/        # Two-tier status tracking
  artifacts/       # Artifact reports, verification results
  orchestrator/    # State checkpointing
  webhooks/        # Subscriptions, events, delivery
  import_export/   # Bulk import/export
  bulk_operations/ # Bulk claim/verify/reject
  skills/          # Skill versioning + performance
  token_usage/     # Token consumption tracking, budgets, cost anomalies, analytics
  quality_assurance/ # UI test runs and findings
  cli/             # Escript CLI commands

lib/loopctl_web/
  controllers/     # 26 JSON API controllers
  plugs/           # Auth pipeline (7 plugs)
```

## Development

```bash
mix precommit       # Full quality gate: compile, format, credo, dialyzer, test
mix test            # Run 1582 tests
mix test --failed   # Re-run failures
mix ecto.reset      # Drop, create, migrate
mix escript.build   # Build CLI binary
```

## Documentation

- **[Orchestration Guide](docs/orchestration-guide.md)** -- How to use loopctl to manage AI development projects (methodology, skills, step-by-step walkthrough)
- **[PRD](docs/prd.md)** -- Full product requirements document
- **[User Stories](docs/user_stories/)** -- 75 stories across 17 epics
- **[Skills](skills/)** -- 6 orchestration skill definitions (read by the orchestrator during the loop)
- **[OpenAPI Spec](https://loopctl.local:8443/api/v1/openapi)** -- Machine-readable API spec (when running)

## Deployment

loopctl deploys as a 3-container Docker Compose stack:

| Service | Image | Port |
|---------|-------|------|
| db | postgres:16 | Internal |
| app | Elixir release | 4000 (internal) |
| nginx | nginx:alpine | 8443 (HTTPS), 8080 (HTTP redirect) |

See [deploy/](deploy/) for nginx config, systemd service, backup scripts, and setup guide.

## Troubleshooting

### `mix setup` fails with "role loopctl_app does not exist"

Create the RLS role used by tests:

```bash
psql -U postgres -c "CREATE ROLE loopctl_app LOGIN PASSWORD 'loopctl_app_pass';"
```

### Health check returns `{"oban":"error"}`

Run pending migrations and restart the app:

```bash
docker compose exec -T app /app/bin/migrate
docker compose restart app
```

### Agent gets 403 on `/stories/:id/claim`

The claim endpoint requires `exact_role: :agent`. User and orchestrator keys cannot claim stories. Create an agent key:

```bash
curl -X POST http://localhost:4000/api/v1/api_keys \
  -H "Authorization: Bearer lc_user_key" \
  -H "Content-Type: application/json" \
  -d '{"name": "worker-1", "role": "agent"}'
```

### Import returns 422 with validation errors

Story numbers must be plain strings like `"1.1"` (no `"US-"` prefix). Epic numbers are integers. Dependencies use number references:

```json
{"story": "1.1", "depends_on": "1.2"}
{"epic": 1, "depends_on": 2}
```

### Superadmin gets 403 on tenant-scoped endpoints

Superadmin keys are tenant-less. Use the `X-Impersonate-Tenant` header for tenant-scoped endpoints:

```bash
curl http://localhost:4000/api/v1/projects \
  -H "Authorization: Bearer lc_superadmin_key" \
  -H "X-Impersonate-Tenant: <tenant_id>"
```

### Orchestrator verify returns 500

The orchestrator API key must have `agent_id` set, linking it to a registered agent with `agent_type: orchestrator`. Create the agent first via `/agents/register`, then create the orchestrator key with `agent_id`:

```bash
# 1. Register the orchestrator agent (using an agent-role bootstrap key)
curl -X POST http://localhost:4000/api/v1/agents/register \
  -H "Authorization: Bearer lc_agent_bootstrap_key" \
  -H "Content-Type: application/json" \
  -d '{"name": "orchestrator-main", "agent_type": "orchestrator"}'
# Note the agent ID from the response

# 2. Create the orchestrator key with agent_id
curl -X POST http://localhost:4000/api/v1/api_keys \
  -H "Authorization: Bearer lc_user_key" \
  -H "Content-Type: application/json" \
  -d '{"name": "orchestrator-main", "role": "orchestrator", "agent_id": "<agent_id>"}'
```

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines and [GitHub Issues](https://github.com/mkreyman/loopctl/issues) for open items.
