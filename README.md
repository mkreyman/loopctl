# loopctl

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
- **OpenAPI 3.0** -- self-documenting API with Swagger UI for agent discovery

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
```

> **Note:** The `CLOAK_KEY` and `SECRET_KEY_BASE` environment variables are only required for production/Docker deployments. Dev uses defaults from `config/dev.exs` and `config/config.exs`.

### Docker Deployment

```bash
# Prerequisites: Docker, Docker Compose

cp .env.example .env
# Edit .env with your secrets (see "Generate Secrets" below)

# Generate TLS certificates for nginx (deploy/certs/ must exist)
mkdir -p deploy/certs
openssl req -x509 -newkey rsa:4096 -keyout deploy/certs/key.pem \
  -out deploy/certs/cert.pem -days 365 -nodes \
  -subj "/CN=loopctl.local"

docker compose build
docker compose up -d
docker compose exec -T app /app/bin/migrate
```

### Generate Secrets

```bash
# SECRET_KEY_BASE
mix phx.gen.secret

# CLOAK_KEY (32 bytes, base64)
elixir -e ':crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()'
```

## API Overview

Once running, the API is self-documenting:

- `GET /` -- Redirects to `/api/v1/`
- `GET /api/v1/` -- Discovery endpoint with links
- `GET /api/v1/openapi` -- Full OpenAPI 3.0 specification (machine-readable)
- `GET /swaggerui` -- Interactive Swagger UI (human-readable)
- `GET /health` -- Health check

### Authentication Flow

loopctl uses role-based API keys. Each role has specific permissions in the two-tier trust model.

1. **Register as a tenant** (no auth required):
   ```bash
   curl -X POST http://localhost:4000/api/v1/tenants/register \
     -H "Content-Type: application/json" \
     -d '{"name": "My Org", "slug": "my-org", "email": "admin@example.com"}'
   # Returns: user-role API key (lc_xxx...)
   ```

2. **Create role-specific keys** (using your user key):
   ```bash
   # Create an agent key for implementation agents
   curl -X POST http://localhost:4000/api/v1/api_keys \
     -H "Authorization: Bearer lc_user_key" \
     -H "Content-Type: application/json" \
     -d '{"name": "worker-1", "role": "agent"}'

   # Create an orchestrator key for verification
   curl -X POST http://localhost:4000/api/v1/api_keys \
     -H "Authorization: Bearer lc_user_key" \
     -H "Content-Type: application/json" \
     -d '{"name": "orchestrator-main", "role": "orchestrator"}'
   ```

3. **Register your agent** (using the agent key):
   ```bash
   curl -X POST http://localhost:4000/api/v1/agents/register \
     -H "Authorization: Bearer lc_agent_key" \
     -H "Content-Type: application/json" \
     -d '{"name": "worker-1", "agent_type": "implementer"}'
   ```

Now the agent key can contract, claim, start, and report stories. The orchestrator key can verify and reject stories.

### Typical Agent Workflow

```
1. Register tenant      POST /api/v1/tenants/register
2. Create project       POST /api/v1/projects
3. Import stories       POST /api/v1/projects/:id/import
4. Register agent       POST /api/v1/agents/register
5. Get ready stories    GET  /api/v1/stories/ready?project_id=...
6. Contract story       POST /api/v1/stories/:id/contract
7. Claim story          POST /api/v1/stories/:id/claim
8. Start implementing   POST /api/v1/stories/:id/start
9. Report done          POST /api/v1/stories/:id/report
10. (Orchestrator)      POST /api/v1/stories/:id/verify  OR  /reject
```

### Roles

| Role | Can Do |
|------|--------|
| `superadmin` | Everything. Cross-tenant via impersonation. |
| `user` | Manage tenant settings, API keys, projects, import/export. |
| `orchestrator` | Verify/reject stories. Write orchestrator state. Force-unclaim. |
| `agent` | Contract, claim, start, report stories. Submit artifacts. |

> **Role design note:** The `user` role is for tenant administration -- managing settings, API keys, and projects. It does not participate in the development trust model. The `orchestrator` and `agent` roles manage the development loop. This separation is by design: tenant admins provision infrastructure while the trust model governs the implementation/verification cycle.

### Two-Tier Trust Model

```
Agent endpoints (exact_role: agent):
  POST /stories/:id/contract
  POST /stories/:id/claim
  POST /stories/:id/start
  POST /stories/:id/report

Orchestrator endpoints (exact_role: orchestrator):
  POST /stories/:id/verify
  POST /stories/:id/reject
  POST /stories/:id/force-unclaim
```

An agent key **cannot** call verify/reject. An orchestrator key **cannot** call claim/start/report. This is enforced at the plug level with strict atom equality -- no role hierarchy bypass.

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
            "number": "US-1.1",
            "title": "Implement login endpoint",
            "acceptance_criteria": [
              {"criterion": "POST /login returns JWT on valid credentials"},
              {"criterion": "Invalid credentials return 401"}
            ]
          },
          {
            "number": "US-1.2",
            "title": "Implement logout endpoint",
            "acceptance_criteria": [
              {"criterion": "POST /logout invalidates the session"}
            ]
          }
        ]
      }
    ],
    "story_dependencies": [
      {"predecessor": "US-1.1", "successor": "US-1.2"}
    ],
    "epic_dependencies": [
      {"predecessor": 1, "successor": 2}
    ]
  }'
```

Each epic requires `number` (integer) and `title` (string). Each story requires `number` (string, e.g. "US-1.1") and `title`. Stories are nested under their epic's `stories` array. Dependencies reference story numbers (for story deps) or epic numbers (for epic deps) and are validated for cycles.

### Webhook Event Types

Subscribe to real-time notifications for these event types:

| Event Type | Fired When |
|------------|------------|
| `story.status_changed` | Agent transitions story status (contract, claim, start, report) |
| `story.verified` | Orchestrator verifies a story |
| `story.rejected` | Orchestrator rejects a story |
| `story.auto_reset` | Rejected story auto-resets to pending |
| `story.force_unclaimed` | Orchestrator force-unclaims a story |
| `epic.completed` | All stories in an epic are verified |
| `artifact.reported` | Agent submits an artifact report |
| `agent.registered` | New agent registers |
| `project.imported` | Work breakdown imported into a project |
| `webhook.test` | Manual test ping via POST /webhooks/:id/test |

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
  cli/             # Escript CLI commands

lib/loopctl_web/
  controllers/     # 26 JSON API controllers
  plugs/           # Auth pipeline (7 plugs)
```

## Development

```bash
mix precommit       # Full quality gate: compile, format, credo, dialyzer, test
mix test            # Run 942 tests
mix test --failed   # Re-run failures
mix ecto.reset      # Drop, create, migrate
mix escript.build   # Build CLI binary
```

## Documentation

- **[PRD](docs/prd.md)** -- Full product requirements document
- **[User Stories](docs/user_stories/)** -- 61 stories across 16 epics
- **[Skills](skills/)** -- 6 orchestration skill definitions
- **[OpenAPI Spec](https://loopctl.local:8443/api/v1/openapi)** -- Machine-readable API spec (when running)

## Deployment

loopctl deploys as a 3-container Docker Compose stack:

| Service | Image | Port |
|---------|-------|------|
| db | postgres:16 | Internal |
| app | Elixir release | 4000 (internal) |
| nginx | nginx:alpine | 8443 (HTTPS), 8080 (HTTP redirect) |

See [deploy/](deploy/) for nginx config, systemd service, backup scripts, and setup guide.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines and [GitHub Issues](https://github.com/mkreyman/loopctl/issues) for open items.
