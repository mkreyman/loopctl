# Changelog

All notable changes to loopctl are documented here.

## [Unreleased] — 2026-07-11 — OKF-curated + RAG Hybrid Knowledge Retrieval (Epic 31)

### Added

- **Hybrid knowledge retrieval** — `Loopctl.Knowledge.hybrid_search/3`
  (`POST /api/v1/knowledge/hybrid_search`, MCP tool `knowledge_hybrid_search`)
  composes the already-shipped retrieval (`search_combined/3`) and curated-source
  identification (`list_curated_sources/2`, US-31.1) subsystems into a single
  resolution layer: `:curated` wins ONLY when a governed curated source's
  ABSOLUTE (never pool-relative, min-max-normalized) confidence score clears a
  scale-matched threshold AND beats the best retrieved candidate by a margin AND
  is authoritative (published, not superseded, not in an open
  `:potential_conflict`); otherwise `:retrieved`. Both branches return an
  identical `results`/`meta` key shape carrying `meta.provenance`
  (`:curated`/`:retrieved`), `meta.confidence`, and `meta.curated_article_id` — a
  caller branches on `meta.provenance` alone, never on which subsystem answered.
  See [`docs/knowledge-hybrid-retrieval.md`](docs/knowledge-hybrid-retrieval.md).
  - **Curated-source identification** (US-31.1) — a GOVERNED, non-self-assignable
    `articles.curated_at`/`curated_by` marker (excluded from `@cast_fields`),
    written only by `Knowledge.mark_curated/3` / `unmark_curated/3` (audited).
    Content edits (title/body/publish) invalidate the marker, forcing
    re-curation. `list_curated_sources/2` applies system-scope precedence (a
    tenant's own curated answer always wins over a `scope: :system` canonical on
    the same topic) and excludes superseded/conflicted articles.
  - **Progressive disclosure** (US-31.3) — `Knowledge.progressive_index/3` /
    `progressive_drill/3` (`GET /api/v1/knowledge/progressive_index` /
    `GET /api/v1/knowledge/progressive/:id`, MCP tools
    `knowledge_progressive_index` / `knowledge_progressive_drill`): a bounded,
    top-K-capped topic index of compact stubs (curated-preferred, one hop of
    `:relates_to` hub enrichment), then a full-body drill.
- **Docs** — new
  [`docs/knowledge-hybrid-retrieval.md`](docs/knowledge-hybrid-retrieval.md) (the
  resolution rule, provenance contract, progressive disclosure, and the
  three-layer model positioning hybrid retrieval within the Knowledge Wiki
  alongside Agent Memory and the Context Retriever); README/CLAUDE.md/AGENTS.md
  extended. **#305 and #306 describe the same feature** — recommend closing one
  as a duplicate rather than tracking separately; the "#305 reconcile
  `docs/cole-medin-self-evolving-wiki.md`" item is already satisfied by the
  epics 28–30 reconciliation (KB hub `fb9abd73`/`3ee5f890`).

### Verification

- **Terminal e2e + negative control** (US-31.5,
  `test/loopctl/knowledge/hybrid_e2e_test.exs`) — a governed curated
  refund-policy article suppresses an unrelated fuzzy chunk (`:curated`, hoisted
  first); archiving that curated article (removed from the published search
  pool, unrelated chunk unchanged) flips the result to `:retrieved` and surfaces
  the previously-suppressed chunk, proving causation; a niche non-curated topic
  falls to `:retrieved`; a near-but-wrong curated doc is never mislabeled
  `:curated`; `:curated`/`:retrieved` meta share an identical key shape. Tenant isolation is proven across the resolver, progressive index/drill,
  and the HTTP API; a system-scoped curated article participates without
  overriding a tenant's own; a superseded/conflicted curated article is never
  authoritative without the conflict surfaced.

## [Unreleased] — 2026-07-10 — Context Retriever (Epic 30)

### Added

- **Context Retriever** — a governed, auto-generated agent query surface over
  loopctl's own STRUCTURED records (`projects`/`stories`/`epics`), the third of
  loopctl's three agent information layers (Knowledge Wiki / Agent Memory /
  Context Retriever). See [`docs/context-retriever.md`](docs/context-retriever.md).
  - **Entity registry** (`Loopctl.ContextRetriever.Entity`/`Registry`, table
    `entity_definitions`) — a tenant admin declares a named **entity** (typed
    `fields` + a backing source) over `POST/PATCH/DELETE /api/v1/entities`. The
    definition IS the executor's field allowlist, bounded by a SERVER per-source
    column allowlist that excludes `tenant_id`/`metadata`/custody columns. Defining
    requires role ≥ `user` + a human-anchored tenant; per-tenant entity count and
    fields-per-entity are capped. Relationships/joins are out of scope for v1.
  - **Tool generator** (`ToolGenerator`) — emits per-entity `cr_filter_<entity>_by_<field>`
    tools (one per filterable field) and a `cr_search_<entity>` tool when a declared
    searchable TEXT field is covered by the source's `search_vector`; served at
    `GET /api/v1/retrieve/tools`.
  - **Executor** (`Executor.run/3`, the security boundary) — `POST /api/v1/retrieve/:entity`
    runs a filter/search parameterized (Ecto-pinned values / `websearch_to_tsquery`
    — never model SQL), dual tenant-scoped (RLS `loopctl_app` role + explicit
    predicate), execute-time allowlist-rechecked, shaped to declared columns only,
    audited fail-closed (`audit_log` `entity_type: "context_retrieval"`; no rows
    without a persisted audit trail), and per-tenant rate-limited (429 over-limit,
    unexecuted). Injection payloads match literally; pagination size + offset are
    capped.
- **MCP dynamic tool listing** — `mcp-server/lib/generated-tools.js` fetches the
  tenant's `cr_*` specs, appends them to ListTools (TTL-cached, negative-cached on
  outage, non-`cr_`/static-colliding specs dropped), and dispatches a `cr_*` call
  to `POST /api/v1/retrieve/:entity` under the same agent key as static reads.
- **Docs** — new [`docs/context-retriever.md`](docs/context-retriever.md) (the
  three-layer model, architecture, security model, surfaces); README/CLAUDE.md/AGENTS.md
  extended to a three-way `retrieve_*` vs `knowledge_*` vs `memory_*` decision
  guide. The #309 "reconcile `docs/cole-medin-self-evolving-wiki.md`" item was
  already satisfied (removed PR #310; content in KB hub `fb9abd73`); the epic folder
  is `epic_30`.

### Verification

- **Terminal e2e + security** (US-30.7) — `Loopctl.E2E.ContextRetrieverJourneyTest`
  (define → ListTools → filter + search via API and the MCP-derived body agree,
  tenant-scoped) and `Loopctl.E2E.ContextRetrieverSecurityTest` (injection in
  filter + search match literally; non-allowlist rejected on every surface;
  cross-tenant define/list/query isolation via context/API/MCP with a positive
  control; no undeclared-column leak; an audit record per execution; `/retrieve`
  429 over-limit) — both run under the non-owner app role. All Context Retriever
  endpoints render at `/swaggerui`.

## [Unreleased] — 2026-07-10 — Agent Memory auto-promotion (Epic 29, Part 2)

### Added

- **Memory promotion pipeline** — compiles a session's short-term turns into durable
  long-term `:promoted` memories without an explicit agent write. Triggered explicitly
  (`POST /api/v1/memory/promote {session_id}` → `Loopctl.Memory.promote_session/1`) or
  by the all-tenants cron `Loopctl.Workers.MemoryPromotionSweepWorker`; both enqueue the
  per-session `Loopctl.Workers.MemoryPromotionWorker` (unique per
  `(tenant_id, subject_id, session_id)`).
  - **Idempotency spine** — a `session_promotions` watermark (session content hash) skips
    an unchanged session WITHOUT an LLM call; re-running promotion adds no net rows
    (measured including superseded).
  - **Confidence gate + hash dedupe/supersede** — survivors above the confidence
    threshold are written with their `confidence`, embedded synchronously at write time,
    exact-deduped on `embedding_content_hash`, and near-dup superseded (source-scoped to
    `:promoted`, never clobbering an `:explicit` memory).
  - **Per-tenant budget** — a compiles/hour cap (atomic reservation incl. in-flight jobs)
    returns HTTP 429 with NO LLM call when exceeded.
  - **TTL-window invariant** — `sweep_interval < sweep_window < session_ttl`, sweep
    promotes oldest-active-first to bound the golden-nugget-loss window.
  - **Prompt-injection resistance** — session content is scope-enforced (the LLM never
    sees foreign turns) and `cross_links` are tenant + visibility validated, so a
    compromised model's foreign/fabricated article link is stripped before write.
- **MCP tool** — `memory_promote` (compile a session; caller's own sessions only; scope
  key-derived). The `/api/v1/memory/promote` endpoint renders at `/swaggerui`.
- **Promotion-quality eval (US-29.5)** — `Loopctl.Memory.PromotionEval` scores the
  compiler's precision/recall against a committed labeled dataset under a reserved,
  structurally-excluded eval subject; calibration only, never gates promotion.
- **Telemetry** — `[:loopctl, :memory_promotion, *]` events (`:swept` `:skipped`
  `:compiled` `:gated_out` `:promoted` `:superseded` `:degraded` `:quota_exceeded`
  `:budget_exceeded` `:failed` `:eval`) so a failing/budget-walled/degraded sweep is
  observable, not silent.
- **Docs** — [`docs/agent-memory.md`](docs/agent-memory.md) extended with the full
  promotion lifecycle, the watermark/budget/TTL invariants, the confidence + eval story,
  the prompt-injection stance, and the Claude Code Stop-hook recipe (cross-ref
  `mkreyman/claude-config#85`, not implemented here);
  [`docs/observability/promotion.md`](docs/observability/promotion.md) documents the
  pipeline metrics.

### Verified (US-29.6, terminal)

- **Promotion e2e** (`Loopctl.Memory.PromotionE2ETest`) — a session promoted via
  `POST /api/v1/memory/promote` is recall-able through BOTH the context and the API with
  `source: :promoted`, `source_session_id`, and `confidence`.
- **Idempotency + cross-scope** (`Loopctl.Memory.PromotionIsolationTest`) — re-promotion
  (explicit + sweep) adds no net rows counting superseded (watermark skip); a promoted
  `(tenant T, subject A)` memory is invisible to tenant U AND subject B via context, API
  (recall / index / forget), with MCP scope-blindness proven in
  `mcp-server/test/memory_tools.test.js`.
- **Unattended safety** (`Loopctl.Memory.PromotionSafetyTest`) — injection produces no
  cross-tenant-linked memory; an over-budget promote is 429 with no LLM call; a compile
  failure emits `:failed` telemetry.

## [Unreleased] — 2026-07-09 — Agent Memory (Epic 28, Part 1)

### Added

- **Agent memory subsystem** — a per-agent PRIVATE working memory, isolated per
  `(tenant_id, subject_id)` and kept strictly separate from the shared Knowledge
  Wiki. Two tiers:
  - **Session memory** (`session_memories`) — short-term, append-only, chronological
    turns/facts with a required `expires_at`, pruned by
    `Loopctl.Workers.SessionMemoryPruneWorker`. No embedding.
  - **Long-term memory** (`memories`) — durable facts embedded as `vector(1536)`
    (populated asynchronously by `Loopctl.Workers.MemoryEmbeddingWorker`) and
    recalled by HNSW cosine similarity, with a supersede/forget lifecycle and a
    per-`(tenant, subject)` live-row quota.
- **HTTP API** — `POST /api/v1/memory` (remember), `POST /api/v1/memory/recall`
  (semantic recall; degrades to a scoped text match, never a silent empty),
  `GET /api/v1/memory` (list; superadmin `?all_subjects=true` oversight), and
  `DELETE /api/v1/memory/:id` (forget). Scope is derived from the API key, never the
  body; the endpoints render at `/swaggerui`.
- **MCP tools** — `memory_remember`, `memory_recall`, `memory_list`, `memory_forget`
  (four tools; scope key-derived, no `tenant_id`/`subject_id` surface).
- **Docs** — [`docs/agent-memory.md`](docs/agent-memory.md): architecture, the two
  tiers + session TTL/pruning, the `subject_id` derivation + BYPASSRLS heavy-read
  structural guard, when to use memory vs knowledge (vs the future context
  retriever), the PII/secret (BYO-embedding) stance, and the auto-promotion (#308) /
  skills-consumer (`claude-config#85`) seams.

### Verified (US-28.5, terminal)

- End-to-end (write via API → recall via context AND API), cross-surface isolation
  (cross-tenant AND cross-subject invisible/immutable across context, API, and MCP,
  on both the semantic and fallback paths), and an `@tag :scale` recall gate proving
  a needle subject recalls its own top-k among an ~80k multi-subject corpus (the
  over-fetch pool + outer subject filter does not starve a subject at scale).

## [Unreleased] — 2026-07-03 — per-tenant BYO Anthropic LLM config + usage (Epic 28, #179)

### Added

- **Per-tenant BYO Anthropic config** — `GET` / `PATCH /api/v1/tenants/me/llm-config`
  (role `:user`): each tenant supplies its OWN Anthropic API key (encrypted at rest,
  never returned — only `has_api_key` + a last-4 hint) and picks a model per operation
  (`extraction_model` / `classification_model` / `merge_model`). loopctl fronts no LLM
  cost. Setting/rotating a key writes an audit event (without the value).
- **Per-tenant LLM usage tracking** — `GET /api/v1/knowledge/llm-usage`
  (role `:orchestrator`): token usage grouped by operation + model + source_type + day
  over an optional date range, with offset/limit pagination (default 90-day lookback).
  Record-only — no budget enforcement.

### Changed — BREAKING (mandatory BYO)

- **Tenant knowledge-LLM work now REQUIRES a per-tenant Anthropic key.** Content
  ingestion, category classification, article merge, and review-finding extraction all
  resolve the tenant's OWN key via `Loopctl.Llm.resolve/2` — there is **no**
  global-system-key fallback. The global `ANTHROPIC_API_KEY` / `:anthropic_provider`
  config path was removed.
- With no key configured, `POST /knowledge/ingest[/batch]` returns **422** with
  `code: "no_api_key"` and a remediation hint; the Oban workers `{:discard}` cleanly
  (no crash, no retry loop). A `[:loopctl, :llm, :blocked]` telemetry event and an
  `llm.blocked_no_api_key` audit entry are emitted when a tenant is blocked.
  (Single-tenant today; no grace period — the operator sets a key.)

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
