# Changelog

All notable changes to loopctl are documented here.

## [Unreleased] — 2026-06-19 — knowledge stats endpoint (#118)

### Added

- `GET /api/v1/knowledge/stats` (and `GET /api/v1/projects/:project_id/knowledge/stats`)
  — aggregate article counts (`total`, `by_category`, `by_status`) via cheap
  `COUNT(*) GROUP BY` with no article metadata loaded. Answers "how many
  articles are here?" without paging the index. Counts span all statuses;
  `by_status` shows the published/draft/archived/superseded split. Role: agent+.
  Exposed via the MCP `knowledge_stats` tool.

## [Unreleased] — 2026-06-19 — knowledge_index field projection (PR #126)

### Added

- `GET /api/v1/knowledge/index` accepts a `fields` query param — a
  comma-separated projection of `id, title, category, tags, status,
  updated_at`. `id` and `category` (the grouping key) are always included;
  unknown fields return `400` (matching the existing `category` validation).
  `meta` now echoes the applied `fields` and adds `has_more` (a synonym for the
  existing `truncated`). The MCP `knowledge_index` tool gains a matching
  `fields` parameter (array or csv). Non-string `fields`/`category`/`tags`/
  `limit`/`offset` params now return `400`/are ignored rather than raising a
  `500`.

### Changed

- **Default response shape changed** (intentional): without `fields`, each
  article object now includes only `id, title, category` instead of all six
  metadata fields. This shrinks the catalog payload dramatically — previously
  the index serialized every field (including the full `tags` array) for up to
  1000 articles per page, producing ~545 KB responses that overflowed MCP
  clients' token limits (#117). Callers that need `tags`/`status`/`updated_at`
  must now request them explicitly via `fields`.

## [Unreleased] — 2026-06-18 — Concurrent article create (PR #116)

### Changed

- `POST /api/v1/articles` (and MCP `knowledge_create`) is now concurrency-safe.
  A create that races/retries into the `(tenant_id, title)` active unique index
  no longer returns a spurious `422 "tenant_id has already been taken"`: an
  **identical-body** collision returns the existing article idempotently as
  **HTTP 200**, and a **different-body** collision returns **`409 title_conflict`**
  (with `existing_article_id`) instead of a 422 the client retries into. The
  unique-violation is attributed to `title` rather than the misleading
  `tenant_id`. Fixes #113/#114.

## [Unreleased] — 2026-04-17 — Import merge + agent ergonomics (PR #105)

### Added

- `POST /api/v1/projects/:project_id/stories` — create a single story by
  epic number (agent-friendly alternative to the UUID-based
  `POST /epics/:epic_id/stories`). Role: `:orchestrator`.
- `POST /api/v1/stories/:id/backfill` — mark a story as verified when the
  work was completed outside loopctl. Records provenance in
  `metadata.backfill` plus an `action: "backfilled"` audit entry and a
  `story.backfilled` webhook. Refused for any story with dispatch lineage
  (non-pending `agent_status`, `assigned_agent_id`,
  `implementer_dispatch_id`, or `verifier_dispatch_id` set) — this is the
  structural guard that makes backfill safe regardless of role. Role:
  `:orchestrator`.
- `story.backfilled` added to the webhook event allowlist.

### Fixed

- `POST /api/v1/projects/:id/import?merge=true` no longer returns
  `epics[0].tenant_id: has already been taken for this project` when
  clients serialize epic numbers as strings. Epic numbers are normalized
  to integers (and story numbers to strings) before validation and DB
  lookups.
- Fallback changeset rendering translates Epic/Story unique-number
  violations into `"Epic 72 already exists in this project. Use
  merge=true..."` regardless of which controller surfaced the error.

### Changed

- Data-op roles: create/update for epics, stories, and dependencies
  lowered from `:user` to `:orchestrator`. DELETE stays at `:user` per
  the destructive-op rule. CLAUDE.md Security section clarified.
- `/loopctl:orchestrate` skill carves out "data operations" (imports,
  creates, backfills, dispatches, reads) as operations the orchestrator
  can perform directly without dispatching a sub-agent. Sub-agents are
  only required for editing application code.

### Security

- `unique_constraint` error translation now scopes to the `_number_`
  index specifically, so future unique constraints (external_id, slug,
  etc.) on Epic/Story schemas won't be mis-reported as "X already
  exists."

## [1.0.0] — 2026-04-12 — Chain of Custody v2

27 stories across 7 phases implementing a six-layer trust model for
AI agent development loops. Full spec: `docs/chain-of-custody-v2.md`.

### Added — Chain of Custody v2 / US-26.0.1

- **Tenant signup ceremony with WebAuthn enrollment**.
  - New public LiveView at `/signup` that collects tenant metadata and
    initiates a FIDO2 registration ceremony via `navigator.credentials.create()`.
    Supports both cross-platform authenticators (YubiKey, etc.) and platform
    authenticators (Touch ID, Windows Hello).
  - `tenant_root_authenticators` table storing `credential_id`, COSE public
    key, attestation format, sign counter, and friendly label per enrolled
    key. One-to-many from tenant to authenticator, unique on
    `(tenant_id, credential_id)`, RLS-enabled.
  - `tenants.status` gains a `:pending_enrollment` value; an Oban cron
    worker (`PendingEnrollmentCleanupWorker`, every 5 minutes) deletes
    tenants stuck in that state past the 15-minute TTL.
  - `Loopctl.WebAuthn.Behaviour` + `Loopctl.WebAuthn.Wax` adapter, wired
    via config-based DI so tests can swap in `Loopctl.MockWebAuthn`.
  - `Loopctl.Tenants.signup/1` atomically creates the tenant, persists
    every verified authenticator, flips the status to `:active`, and
    writes the audit log genesis entry in a single `Ecto.Multi`.
  - OpenAPI schemas: `TenantSignupRequest`, `WebAuthnChallenge`,
    `WebAuthnAttestation`; `TenantResponse` updated to surface the new
    `pending_enrollment` status.
  - New post-signup onboarding LiveView at `/tenants/:id/onboarding`
    that scaffolds the four-step operator checklist (audit key
    generation, system article tour, first project, first agent).
  - JavaScript `WebAuthn` hook in `assets/js/hooks/webauthn.js`.
  - `CoreComponents` module providing `<.input>`, `<.icon>`, and
    `<.flash_group>` in the design-system palette.

### Removed

- `POST /api/v1/tenants/register` and the `Loopctl.Auth.register_tenant/1`
  helper it called. Chain of Custody v2 requires a WebAuthn-gated signup
  ceremony; the legacy unauthenticated tenant creation path has no
  replacement and any request to it now 404s. This enforces AC-26.0.1.7.
