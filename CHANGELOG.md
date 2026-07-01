# Changelog

All notable changes to loopctl are documented here.

## [Unreleased] — 2026-06-30 — docs sync + agents'-KB endpoints backfill

### Added

- **KB conflict resolution API** — `GET /api/v1/knowledge/conflicts` (list potential-conflict
  article pairs the auto-linker/nightly lint flagged as too-similar-to-coexist) and
  `POST /api/v1/knowledge/conflicts/resolve` (record a `dismiss`/`supersede`/`merge` verdict;
  the nightly executor acts on `supersede`/`merge` only at `confidence: high`, and `merge`
  LLM-synthesizes both sources into one new draft, never auto-published). Role: agent.
  MCP tools `knowledge_conflicts`, `knowledge_resolve_conflict` (MCP 2.26–2.28).
- **`GET /api/v1/knowledge/analytics/retrieval-metrics`** — daily retrieval-precision time
  series (share of search results the agent then opened). Role: orchestrator. MCP tool
  `knowledge_retrieval_metrics` (MCP 2.29).
- **`GET /api/v1/knowledge/curation-log`** — human-readable feed of KB curation adjustments
  (novelty-gate `gate_duplicate`/`gate_draft`; conflict `supersede`/`merge`/`dismiss`),
  recorded only while a tenant has `settings.kb_curation_log` enabled (default off).
  Role: orchestrator. MCP tool `knowledge_curation_log` (MCP 2.30).
- **Creativity primitives** — `POST /api/v1/knowledge/novelty`, distant-pairs, random-walk,
  and suggested-links endpoints (MCP `knowledge_novelty`, `knowledge_distant_pairs`,
  `knowledge_random_walk`, `knowledge_suggest_links`).
- **API root discovery links** — `GET /api/v1/` now also returns `discovery`, `routes`, `wiki`,
  and `mcp_server` pointers so agents hitting the root have a path to the MCP server and
  discovery documents instead of dead-ending.

### Docs

- Corrected the MCP tool count to **69** (was 57/65) across the README, `mcp-server/README.md`,
  the landing/docs pages, and `CLAUDE.md`, and documented the 4 previously-undocumented tools.
- Fixed drifted docs: UI-test endpoints are nested under `/projects/:project_id/ui-tests`
  (README); `verified_status` values are `unverified`/`verified`/`rejected` (not `pass`/`fail`),
  and `initial_verified_status` on import is honored only for a superadmin caller
  (orchestration guide); `knowledge_export` has no `obsidian` format and its download needs a
  user key (`mcp-server/README.md`); `GET /` serves the HTML landing page (it does not redirect).
- `GET /api/v1/routes` is now described as a curated index (not the exhaustive surface), points
  to the OpenAPI spec, and lists the CoC v2 dispatch routes, `recover-cap`, `acceptance_criteria`,
  and the new knowledge endpoints.
- Refreshed `model_name` examples (OpenAPI schema, MCP tool descriptions, PRD) to the current
  `claude-sonnet-5` id. `model_name` remains a free-form string and cost is caller-reported, so
  no code change is needed to record a new model.

## [Unreleased] — 2026-06-25 — heavy-read pgbouncer outage fix (US-27.13)

### Fixed

- **HeavyReadRepo pgbouncer `08P01` outage (US-27.13):** the dedicated heavy-read pool
  carried a `statement_timeout` connection STARTUP parameter (`parameters:` in
  `config/runtime.exs`), which Fly MPG's pgbouncer rejects with
  `FATAL 08P01 unsupported startup parameter`, crash-looping the pool so it never
  established a connection — every heavy vector/enumeration endpoint (`suggested_links`,
  semantic search, `distant_pairs`, `novelty`, heavy enumeration) hung then `503/504`'d.
  It was invisible to CI because the suite connects to direct Postgres (which accepts the
  startup param) and aliases heavy reads to `AdminRepo`. The server-side `statement_timeout`
  is now applied per-read via `SET LOCAL` inside a transaction (the pgbouncer-safe mechanism).

### Changed

- **Heavy-read `statement_timeout` configuration:** set via `HEAVY_READ_STATEMENT_TIMEOUT_MS`
  (default 10s) and the per-endpoint `:heavy_read_statement_timeout_overrides` map, applied
  per-read via `SET LOCAL` — **NOT** a connection startup `:parameters` value
  (pgbouncer-incompatible). A server GUC that must persist at connect is set via `ALTER ROLE`
  (the documented `hnsw.ef_search` lever), never a startup parameter.

### Added

- **Recurrence guards:** `config_pgbouncer_safe_parameters_test.exs` (scans the config
  source — incl. `runtime.exs` — and fails on any pgbouncer-incompatible repo `:parameters`)
  and a pgbouncer-layer e2e (`pgbouncer_startup_params_test.exs` + a CI `pgbouncer-e2e` job
  that gates deploy) which reproduces the `08P01` rejection and proves `SET LOCAL` enforces
  through the proxy.

## [Unreleased] — 2026-06-22 — knowledge wiki harvest-hardening (#132–#138)

A batch of Knowledge Wiki API changes for reliable agent/harvest workflows.
(Supersedes the #120 draft-by-default + orchestrator-publish-gate notes below.)

### Added

- **Idempotency_key (#137):** `POST /api/v1/articles` accepts `idempotency_key`
  (per-article, max 255). Re-creating with the same key is a no-op that returns
  a reference to the existing article (`deduplicated: true`, id only — no body),
  preventing partial duplicates on re-capture. Distinct from
  `source_type`/`source_id` (a shared source identifier).
- **Lag-free enumeration (#134/#135):** `GET /api/v1/articles` filters by
  `source_type`, `source_id`, and `idempotency_key`; new MCP `knowledge_list`
  wraps it. This is the lag-free, all-status read of record for
  dedup/idempotency/repair — vs `knowledge_search`, which is ranked,
  published-only, and lags writes.
- **Bulk delete (#136):** `POST /api/v1/knowledge/bulk-delete` (role user) —
  partial-success soft-delete by `article_ids`, `source_type`+`source_id`, or
  `tag`+`confirm:true` (exactly one selector). MCP `knowledge_bulk_delete`.
- **Ingest publish opt-in (#133):** `POST /api/v1/knowledge/ingest` + `/batch`
  accept `publish: true`; extracted articles stay **draft by default**
  (lower-trust LLM output) but can be published in one step.

### Changed

- **Publish-on-create is the default for every role, including agent (#133)** —
  `POST /api/v1/articles` publishes immediately; draft is now the opt-in
  (`draft: true` / `status: "draft"`). The orchestrator-only publish gate is
  removed on the create path (publishing a wiki article is neither destructive
  nor story chain-of-custody); the standalone publish endpoint and system-scope
  gate are unchanged.
- **Bulk-publish is partial-success + uncapped (#132, #138.3):** publishes every
  valid draft and returns per-id outcomes (published/skipped/not_found/errored)
  in `meta.results` instead of failing the whole call; already-published ids are
  skipped (idempotent); the 100-id cap is gone (auto-chunked, ≤5000).
- **Tag cap raised 20 → 50 (#138.2).**

### Fixed

- **Invalid `?status=`/`?category=` → 400 with allowed values (#138.1)** on
  `GET /api/v1/articles` (was a 404/500 from an `Ecto.Enum` cast); malformed
  list/map query params no longer 500.
- **429 `Retry-After` is always ≥ 1s (#136)** (was `reset_at - now`, which could
  be ≤ 0 at a window boundary); rate limits documented on `RateLimitError`.

### Docs

- Documented the witness/STH request-header workflow for non-MCP clients (#138.4)
  and the search-vs-list distinction.

## [Unreleased] — 2026-06-19 — create-and-publish + draft note (#120)

### Added

- `POST /api/v1/articles` accepts `publish: true` to create-and-publish in one
  call. This is gated at **orchestrator+** (mirrors `POST /articles/:id/publish`);
  an agent requesting publish gets `403 publish_requires_orchestrator`.

### Changed

- The create response now carries a `note` making the lifecycle explicit —
  articles are created as **draft** (not visible in search/index/context) unless
  published, which the two-step flow made easy to miss (#120).

### Security

- The initial article status is now set **server-side** on create; a
  caller-supplied `status` is ignored except that `status: "published"` is
  treated as `publish: true` (and gated the same way). This closes a gap where
  an agent could self-publish — or set `archived`/`superseded` — by passing
  `status` directly in the create payload, bypassing the orchestrator publish
  gate.

## [Unreleased] — 2026-06-19 — search total_count semantics (#119)

### Changed

- `GET /api/v1/knowledge/search` now returns `meta.total_count_scope` (and
  `meta.search_mode`) so callers can tell what `meta.total_count` counts in the
  active mode: `keyword_matches` (stop-word-filtered tsquery matches),
  `ranked_corpus` (semantic ranks all embedded published articles — that
  embedded set's size, not a match count, and ≤ the published count),
  `merged_candidates` (combined: deduped union of a keyword and a semantic
  sub-search, each capped at 50, so up to ~100), or `filtered_set` (list mode:
  complete set). The
  OpenAPI description and MCP tool docs now spell out the per-mode semantics and
  stop-word behavior, and direct corpus-sizing to list mode or
  `GET /knowledge/stats` (#119). No value changed — `total_count` was already
  uncapped per mode; this makes its meaning explicit.

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
