# Changelog

All notable changes to `loopctl-mcp-server` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## 2.22.0 — 2026-06-24 (bulk-delete: set-based + irreversible hard delete)

### Added

- **`knowledge_bulk_delete`** gains four params for US-27.12:
  - `dry_run` (bool) — preview only, mutates nothing; returns `meta.would_affect`.
    With `hard:true` the preview also returns a single-use `meta.token` (or, for a
    selector larger than the frozen-token bound, a `meta.confirm_hash`).
  - `hard` (bool) — IRREVERSIBLE hard delete (vs the default reversible archive).
    Two-step ceremony: dry-run with `hard:true` to obtain a token, then call again
    with `hard:true` + that `token` to FK-correctly delete the FROZEN id-set
    (article_links removed first, access events cascade). The token is server-minted,
    single-use, and TTL-bounded.
  - `token` (string) — the frozen-set token from the dry-run, required for the hard
    delete.
  - `confirm_hash` (string) — for an oversized hard-delete selector (no token):
    echo back the dry-run's `meta.confirm_hash` to re-confirm the id-set hasn't
    drifted.
  Requires `LOOPCTL_USER_KEY` for every variant (agents/orchestrators get 403).

### Changed

- **`knowledge_bulk_delete` response shape (default soft archive).** The default
  (soft) path is now **set-based** (one statement + one audit event) instead of
  per-row. The response is a backward-compatible superset: `meta.counts`
  (`requested`/`archived`/`skipped`/`not_found`/`errored`) and `meta.count` are
  still present (so existing consumers of the partial-success warning keep working),
  but **`meta.results` is now always `[]`** (the set-based op has no per-id
  breakdown — use `meta.affected`/`meta.counts`), and **`meta.counts.skipped` is
  redefined** as `resolved − affected` (rows already archived/inactive) rather than
  a per-id skip-with-reason. New additive fields: `meta.affected`, `meta.set_based`,
  `meta.op`. A zero-match selector now returns `200` with `affected: 0` (idempotent)
  instead of `400`.

## 2.21.1 — 2026-06-24 (novelty accepts the AC request shape)

### Fixed

- **`knowledge_novelty`** now accepts the documented `texts: [string]` shape (the
  #152 AC / CREATIVITY.md contract) in addition to `ideas: [{text}]`, and also a
  bare `ideas: [string]`. All forms are coerced to idea objects server-side, so
  the documented request shape and the idea-synthesizer consumer agree. The tool
  schema documents both `texts` and `ideas`, and neither is `required` (provide
  one). (#169)

## 2.21.0 — 2026-06-24 (agent-memory trust model enforced)

### ⚠️ Behavior change (server-side)

The agent-memory trust model that 2.19.0 shipped as **advisory-only** is now
**enforced** by the server (#163). This changes what agent-role API keys can
write and read:

- **Write — `agent_id` is bound to the key.** When an **agent**-role key creates
  an article carrying agent-memory metadata (`agent_id`/`memory_type`/`visibility`),
  the server stamps `metadata.agent_id` from the key's verified agent identity,
  overriding any value in the body. An agent can no longer write a memory under
  another agent's identity. An agent key with no agent identity gets **403
  `agent_identity_required`** for such a write. Higher roles (orchestrator/user)
  may still attribute on behalf of others.
- **Read — `visibility` is enforced on EVERY agent-reachable read.** For
  **agent**-role reads, articles whose `metadata.visibility` is `private` or `owner`
  are returned only to the owning agent; others get `404`/exclusion with no existence
  leak. `shared` and non-memory articles are unaffected; higher roles continue to see
  everything. Covered surfaces: `knowledge_get` (incl. its linked-article refs),
  `knowledge_list`/index, `knowledge_search`, `knowledge_context` (incl. linked refs),
  `knowledge_stats`, `knowledge_count`, `knowledge_facets`, `knowledge_graph`,
  `knowledge_suggest_links`, `knowledge_distant_pairs`, `knowledge_random_walk`, and
  `knowledge_novelty` (private priors are excluded from the comparison set). `owner`
  and `private` are enforced identically (owner-only) in this version.

`visibility` scoping is now a real trust barrier for agent keys (not just a
convenience filter). No MCP tool signatures changed.

### Migration note

Identity is the key's registry `agent_id` (a UUID). Memories written **before** this
change with a self-asserted, non-UUID `agent_id` string won't match their owner's key
identity, so the owning agent may no longer read its own pre-#163 private/owner
memories (they remain visible to higher roles).

**Migration path for operators:**
1. Identify affected articles (private/owner visibility with non-UUID agent_id):
   ```sql
   SELECT id, title, metadata->>'agent_id' as agent_id
   FROM articles
   WHERE status = 'published'
     AND COALESCE(metadata->>'visibility', 'shared') IN ('private', 'owner')
     AND metadata->>'agent_id' IS NOT NULL
     AND metadata->>'agent_id' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
   ```
2. For each affected article, determine the correct UUID for its owner (e.g., from agent registry or auth logs).
3. Backfill via REST API (higher-role key required):
   ```
   PATCH /api/v1/knowledge/articles/:id {
     "metadata": {
       "agent_id": "<correct-uuid>"
     }
   }
   ```
   Or treat affected articles as a clean break (keep them archived/read-only to higher roles only).

Memories written after this change are always key-stamped with the API key's UUID.

## 2.20.1 — 2026-06-24 (honest story pagination)

### Fixed

- **`list_stories` / `list_ready_stories`** no longer silently clamp `limit` to 20.
  They default to 20 but now honor an explicit `limit` up to the server's max (500),
  so paging by advancing `offset` no longer skips stories. Tool schemas document the
  `default 20, max 500` contract. (#155)

## 2.20.0 — 2026-06-23 (creativity primitives)

### Added

- **`knowledge_distant_pairs`** — distant-but-bridgeable article pairs in the
  optimal-novelty embedding band (cosine distance min..max, default 0.3–0.7).
  Optional `bridge_path` requires a ≤2-hop link-graph path. Paginated. The
  remote-associates generator for computational-creativity ideation. (#152 A1)
- **`knowledge_novelty`** — score ideas by novelty: each idea's text is embedded
  and compared to the nearest prior proposal (default tag `proposal`), returning
  `novelty_score` = cosine distance (0 = identical, higher = more novel up to 2.0;
  `null` when the idea text is blank, no priors exist, or embedding fails — with
  `meta.prior_count` (count of embedded priors actually compared against)). (#152 A2)
- **`knowledge_random_walk`** — random walk through the link graph from a starting
  article (no cycles), surfacing unexpected connections for incubation. (#152 A3)

  Backed by `GET /api/v1/knowledge/pairs`, `POST /api/v1/knowledge/novelty`,
  `GET /api/v1/knowledge/walk`.

## 2.19.0 — 2026-06-23 (agent-memory scoped context)

### Added

- `knowledge_context` gains agent-memory scoping filters: `memory_types`
  (comma-separated, OR — observation/finding/summary/decision/question/task),
  `agents` (comma-separated agent_ids, OR), and `conversation_id` (exact). These
  filter on the article's `metadata` (JSONB containment), turning the wiki into a
  queryable agent memory scoped to a memory type, agent, or conversation. Server
  validates `memory_type`/`visibility`/`agent_id` conventions on write when an
  `agent_id` is present, and adds a GIN index on `metadata`. (#151)

### ⚠️ Trust Model (v1 Conventions)

- **Agent-memory `agent_id` is self-asserted**, not bound to the authenticated
  API key. An agent can write memories tagged with another agent's identity.
  Operators should assume agents can spoof authorship — do not use agent-memory
  scoping for security-sensitive data. Future versions will bind `agent_id` to
  the API key identity for verified attribution.

- **`visibility` field** (`shared`/`private`/`owner`) is **stored but not
  enforced** in v1. Any authenticated agent can retrieve any other agent's
  memories via `agents=` filters, regardless of visibility. The field is an
  advisory label for future RLS-based enforcement. Treat memory isolation as a
  convenience filter, not a trust barrier.

- Follow-on stories for write-path enforcement (binding `agent_id` to API key,
  `visibility` enforcement) are tracked separately with the operator's explicit
  sign-off. **Superseded by 2.21.0 — both are now enforced (#163).**

## 2.18.0 — 2026-06-23 (suggest typed links)

### Added

- **`knowledge_suggest_links`** — ranked typed-link *candidates* for an article by
  embedding similarity, **read-only** (creates nothing). Excludes the article itself
  and any already-linked article (either direction, any type); only embedded
  published articles. Returns `{id, title, category, similarity_score}` highest-first
  so the caller can create a *typed* link (relates_to/derived_from/contradicts/
  supersedes) — unlike the auto-linker's ambient `relates_to`. Optional `threshold`
  (cosine floor, default 0.5) and `limit` (default 5). Backed by
  `GET /api/v1/knowledge/articles/:id/suggested_links`. (#150)

## 2.17.0 — 2026-06-23 (knowledge graph traversal)

### Added

- **`knowledge_graph`** — multi-hop traversal of the published article-link graph
  from a starting article (depth 1–3). Bidirectional, cycle-safe, bounded to 100
  nodes / 500 edges (`truncated` flags a cap hit). Returns `nodes`
  (id/title/category/depth) + `edges` (source/target/relationship_type) so agents
  can explore typed connections beyond the 1-hop links in `knowledge_context`.
  Backed by `GET /api/v1/knowledge/graph`. (#149)

## 2.16.0 — 2026-06-23 (bulk unpublish)

### Added

- **`knowledge_bulk_unpublish`** — revert published articles to draft in bulk,
  partial-success style (the mirror of `knowledge_bulk_publish`). REQUIRES
  `LOOPCTL_USER_KEY`. Per-id outcomes (`unpublished`/`skipped`/`not_found`/
  `errored`), de-duplicated, auto-chunked, ≤5000/call; surfaces a warning when the
  run is partial. Articles are not deleted (re-publish to restore; use
  `knowledge_bulk_delete` to archive). Completes #148 M3. (#148 A6/M3)

## 2.15.0 — 2026-06-23 (AND-tag filtering + count/facets)

### Added

- **`knowledge_count`** — count articles matching filters (category, status, tags,
  `match`, source/idempotency, project) **without returning rows**. With
  `tags` + `match: "all"` (+ `status`) it answers "how many published articles
  tagged both X and Y" in one call. (#148 A2/A4)
- **`knowledge_facets`** — count articles grouped by distinct tag, with an
  optional `tag_prefix` to get the **distinct count of a tag family** (e.g. how
  many distinct `book-*` books) plus per-member totals, no row enumeration. (#148 A3)
- **`match` param** on `knowledge_list`, `knowledge_index`, and `knowledge_search`:
  `any` (default, OR — back-compat) or `all` (AND — articles carrying every listed
  tag). Lets agents ask for "book hubs" (`tags: "book,hub", match: "all"`) instead
  of the union. (#148 A2 / M1)

## 2.14.0 — 2026-06-23 (lag-free enumeration honors large pages)

### ⚠️ Breaking Change

- **`knowledge_list` is now body-less by default**: it returns an article
  *summary* (id, title, category, status, tags, source/idempotency fields,
  timestamps) and **no longer includes `body`** unless you pass
  `include_body: true`. This makes large enumeration (the tool's main job: dedup/
  repair/existence checks) safe to page up to `limit=1000` without ~100 MB
  responses. With `include_body: true` the page is bounded by a ~5 MB
  serialized-body budget and may return fewer than `limit` rows — continue via
  `meta.next_offset` while `meta.has_more` is true. For a single full body use
  `knowledge_get`; for the relevant bodies use `knowledge_context`; for a bulk
  content dump use `knowledge_export`. Callers that read `body` from
  `knowledge_list` rows must either pass `include_body: true` or switch to one of
  those tools.
- **`knowledge_drafts` behavior envelope changed**: Requests with `limit` values
  between 21–1000 now return up to 1000 rows (previously silently clamped to 20).
  Requests with `limit > 1000` now return **400 Bad Request** (previously
  succeeded and returned ≤20 rows). Callers relying on "drafts enumeration never
  errors" or "drafts requests always fit in a 20-row buffer" will need updates.
  Draft rows now also carry the full body bounded by the same ~5 MB byte budget.

### Changed

- `knowledge_drafts` now passes `limit` through to the server (like
  `knowledge_list`/`knowledge_index`/`knowledge_search`) instead of silently
  clamping it to 20 client-side. The server honors a page size up to 1000 and
  returns **400** for a larger limit — never a silent clamp — so draft
  enumeration via offset/limit reaches every row. Schema `maximum` raised
  20 → 1000. Note: Schema `maximum` is advisory; servers always enforce the cap
  at the API layer with a 400 error.
- `knowledge_list` schema documents the raised max page size (100 → 1000) and the
  honor-or-400 contract, matching the server change for #148 A1.

### Fixed

- Closes the MCP half of the #148 A1 silent-truncation bug: a draft enumeration
  requesting `limit > 20` previously received only 20 rows while the caller, if
  advancing `offset` by the requested limit, skipped the rest.

## 2.13.0 — 2026-06-22 (ingest publish opt-in)

### Added

- `knowledge_ingest` and `knowledge_ingest_batch` accept `publish: true` to
  publish extracted articles immediately. Ingested (LLM-extracted) articles
  remain **drafts by default** — lower-trust output staged for review, distinct
  from `knowledge_create`'s publish-by-default — but can now be published in one
  step. `knowledge_ingest_batch` supports a batch-level `publish` default and a
  per-item override. Completes loopctl #133 (the ingest half).

## 2.12.0 — 2026-06-22 (knowledge_bulk_delete)

### Added

- New `knowledge_bulk_delete` tool (requires `LOOPCTL_USER_KEY`): bulk
  soft-delete (archive), partial-success. Selectors: `article_ids`,
  `source_type`+`source_id` (dedup cleanup), or `tag`+`confirm:true`
  (high-blast-radius, confirm required). Per-id outcomes
  (archived/skipped/not_found/errored) in `meta.results`; idempotent
  (already-archived skipped); auto-chunked, ≤5000/call; emits a warning when
  the run is partial. Wraps the new `POST /api/v1/knowledge/bulk-delete`. (loopctl #136)

### Note

- 429 responses carry a `Retry-After` header (always ≥1s) plus
  `X-RateLimit-*`; default limit 300 req/min/key (3x/tenant). (loopctl #136)

## 2.11.0 — 2026-06-22 (knowledge_list: lag-free enumeration)

### Added

- New `knowledge_list` tool: lists articles with full fields (status, tags,
  source_type, source_id, idempotency_key, timestamps), filtered by
  tags/status/source_type/source_id/idempotency_key/category and paginated. It
  wraps `GET /api/v1/articles` — the lag-free, all-status read of the DB of
  record — so MCP-only clients can enumerate/dedup/repair and run idempotency/
  existence checks reliably right after a write, instead of the ranked,
  published-only, write-lagging `knowledge_search`. (loopctl #134, #135)
- `GET /api/v1/articles` now also filters by `source_type`, `source_id`, and
  `idempotency_key`.

## 2.10.0 — 2026-06-22 (knowledge_create idempotency_key + provenance)

### Added

- `knowledge_create` now accepts `idempotency_key` for idempotent capture:
  re-creating with the same key is a clean no-op that returns the existing
  article (`deduplicated: true`) instead of a partial duplicate — distinct from
  `source_type`/`source_id`, which mark a shared source across many articles.
- `knowledge_create` now forwards `source_type` and `source_id` (previously
  dropped by the tool) so provenance can be recorded on create. (loopctl #137)

## 2.9.0 — 2026-06-22 (knowledge_bulk_publish partial success)

### Changed

- `knowledge_bulk_publish` is now **partial-success** and **idempotent**: every
  valid draft is published; other ids are reported per-id as `skipped` (already
  published, or archived/superseded), `not_found`, or `errored` instead of
  failing the whole call with a 422/404. The **100-id cap is removed** (larger
  requests are auto-chunked server-side) and duplicate ids are de-duplicated.
  The response gains `meta.counts` and `meta.results`; `meta.count` still equals
  the number actually published. Safe to retry. (loopctl #132, #138)

## 2.8.0 — 2026-06-22 (knowledge_create publishes by default)

### Changed

- `knowledge_create` now **publishes on create by default** for every role
  (including agent), making the article immediately visible in
  search/index/context — no separate publish step or orchestrator key needed.
  The previous `publish: true` flag is replaced by `draft: true`, which stages
  the article for later review instead (publish it afterwards with
  `knowledge_publish`). This eliminates the most common place harvested
  knowledge silently rotted as an invisible draft. (loopctl #133)

## 2.7.0 — 2026-06-19 (knowledge_create publish-in-one-call)

### Added

- `knowledge_create` accepts `publish: true` to create-and-publish in one call.
  A publish request is routed through `LOOPCTL_ORCH_KEY` (orchestrator role,
  mirroring `knowledge_publish`); the server returns 403 if that role is
  missing. On an agent-only install (no `LOOPCTL_ORCH_KEY`/`LOOPCTL_API_KEY`) a
  `publish: true` request returns a clear "requires orchestrator role" tool
  error instead of a cryptic keyless failure. Without publish, articles are
  still created as **draft**.

### Changed

- The `knowledge_create` description now states up front that articles are
  created as a draft and are NOT visible to agents until published, and the
  underlying `POST /articles` response carries a `note` making the draft (or
  published) outcome explicit (issue #120). The two-step draft→publish flow was
  easy to miss, leaving articles silently invisible.

## 2.6.1 — 2026-06-19 (search total_count clarity)

### Changed

- `knowledge_search` responses now include `meta.total_count_scope`, a
  self-describing label for what `meta.total_count` counts in the active mode
  (`keyword_matches`; `ranked_corpus` = embedded published set, ≤ published
  count; `merged_candidates` = deduped union of two 50-capped sub-searches, up
  to ~100; or `filtered_set`), plus `meta.search_mode`. The tool description
  documents the per-mode
  semantics and stop-word behavior so callers stop misreading `total_count` as
  a corpus total (issue #119). For sizing the wiki, use list mode or
  `knowledge_stats`.

## 2.6.0 — 2026-06-19 (knowledge_stats)

### Added

- `knowledge_stats` — aggregate article counts (`{ total, by_category,
  by_status }`) via a cheap `COUNT(*) GROUP BY`, with no article metadata
  loaded. This is the tool to answer "how many articles are in this project?":
  `knowledge_index` pages article metadata (capped per request) and
  `knowledge_search`'s `total_count` is query-dependent, so neither could give a
  reliable project total (issue #118). Optional `project_id` scopes the counts.
  Backed by `GET /api/v1/knowledge/stats` (and the project-scoped variant).

## 2.5.0 — 2026-06-19 (knowledge_index field projection)

### Added

- `knowledge_index` now accepts a `fields` projection (default
  `id,title,category`; request `tags`/`status`/`updated_at` explicitly; `id`
  and `category` are always included). Previously the index always serialized
  every metadata field — including the `tags` array — for up to 1,000 articles
  per page, producing payloads large enough to overflow an MCP client's token
  limit (issue #117). The default projection keeps the catalog small while
  leaving the heavier fields available on request. `meta` echoes the applied
  `fields` and adds `has_more` (a synonym for `truncated`).

## 2.4.1 — 2026-06-18 (Concurrency-safe article create)

### Changed

- `knowledge_create` (and the underlying `POST /articles`) is now concurrency-
  safe. A create that races/retries into the `(tenant_id, title)` active unique
  index no longer returns a spurious `422 "tenant_id has already been taken"`:
  if the colliding payload has an **identical body** (ignoring surrounding
  whitespace — the unforgeable server-side content signal) the existing article
  is returned idempotently (HTTP 200); a **different-body** same-title collision
  returns a clear `409 title_conflict`
  (with the existing article id) instead of a 422 the client retries into. The
  unique-violation message is also corrected to be attributed to `title` rather
  than the misleading `tenant_id`. Fixes #113/#114.

## 2.4.0 — 2026-06-18 (OKF interchange)

### Added

- `knowledge_okf_export` — export the wiki as a portable OKF (Open Knowledge
  Format) v0.1 bundle: a tree of markdown files with YAML frontmatter. Writes
  the bundle to `out_dir` (one `.md` per concept, plus `index.md`/`log.md`) or
  returns it inline as `{files, meta}`. Requires `LOOPCTL_USER_KEY`.
- `knowledge_okf_import` — import an OKF bundle from a local directory. Reserved
  files are skipped; each concept is created or (with `merge`, default true)
  updated in place when it matches an article we previously imported. Unknown
  frontmatter types/keys are tolerated and preserved; all imports land as drafts.
  Returns a per-file report. Requires `LOOPCTL_USER_KEY`.

### Rationale

OKF (Google Cloud's vendor-neutral spec, v0.1) makes the wiki portable —
git-shippable, GitHub-renderable, and interoperable with other agents/tools —
as an interchange layer without changing loopctl's DB-backed internals. Both
tools stay at `role: :user` because export is a bulk knowledge egress and import
bulk-mutates curated articles.

## 2.3.0 — 2026-06-18 (Knowledge enumeration & pagination)

### Added

- `knowledge_search` now accepts `offset` for pagination, and `q` is now
  **optional** when `tags` and/or `category` are supplied. In that list mode the
  server returns the complete filtered set (no relevance ranking) paginated via
  `offset`/`limit` over `meta.total_count`, so an agent can enumerate every
  article carrying a tag/category instead of unioning many keyword queries.
  Fixes #108.
- `knowledge_index` now accepts `category`, `tags`, `offset`, and `limit`.
  Results are ordered deterministically so pagination reaches every article
  (previously a fixed cap silently dropped whole categories), and
  `meta.categories` reports per-category totals over the entire filtered set.
  An unknown `category` is rejected with `400` rather than silently ignored.
  Fixes #109.

### Rationale

There was no reliable way to enumerate all articles for a given tag/category:
`knowledge_search` forced a keyword that was AND-ed with the filter and capped
per query, and `knowledge_index` silently ignored `category`/`tags`/`offset`
while truncating later categories. Both paths now support complete, paginated
enumeration.

## 2.2.0 — 2026-04-22 (Wiki curation tools)

### Added

- `knowledge_unpublish` — revert a published article back to draft. Hides it
  from agent search/context without deleting; re-publish via
  `knowledge_publish`. Requires `LOOPCTL_USER_KEY` (destructive, `role: :user`).
- `knowledge_archive` — soft-delete an article (draft or published). Hidden
  from search/context/index; row retained for audit. Requires
  `LOOPCTL_USER_KEY`.
- `knowledge_delete` — alias for `knowledge_archive` (DELETE verb on the REST
  API archives under the hood). Requires `LOOPCTL_USER_KEY`.

### Rationale

Previously agents could create and publish articles but had no way to retract
bad drafts via MCP — low-signal articles (session summaries, commit recaps)
were piling up in the wiki with no cleanup path short of curl. These three
tools close the curation loop. All three stay at `role: :user` per the
"destructive ops above orchestrator" rule in `CLAUDE.md`.

## 2.1.0 — 2026-04-17 (Agent ergonomics)

### Added

- `import_stories` now accepts `merge: true` to append stories to epics that
  already exist (previously duplicates returned 409 with no way forward).
- `import_stories` now accepts `payload_path` (absolute JSON file path) so
  large imports can bypass inline tool-call size limits. When both
  `payload` and `payload_path` are passed, inline wins.
- `create_story` — create a single story inside an existing epic. Accepts
  either `epic_id` (UUID) or (`project_id` + `epic_number`). No more
  wrapping a single story in a bulk import payload.
- `backfill_story` — mark a story as verified when the work was completed
  outside loopctl. Records provenance (`reason`, `evidence_url`,
  `pr_number`) in `metadata.backfill` plus an audit entry and a
  `story.backfilled` webhook. Refused for any story with dispatch
  lineage (non-pending `agent_status`, `assigned_agent_id`,
  `implementer_dispatch_id`, or `verifier_dispatch_id` set) — cannot be
  used as a chain-of-custody shortcut.

### Changed

- `import_stories` is type-tolerant on epic numbers. Integer and numeric
  string both normalize to integers before DB lookup, fixing the
  `epics[0].tenant_id: has already been taken for this project` error
  when clients serialized epic numbers as strings.
- `resolvePayload` validates `payload_path` before reading: requires an
  absolute path, refuses `/proc`, `/dev`, `/sys` prefixes, rejects
  non-regular files, enforces a 5 MiB size cap.
- Domain error translation for Epic/Story unique-number violations —
  duplicate imports and direct creates now return
  `"Epic 72 already exists in this project. Use merge=true..."` instead
  of the raw Ecto constraint message.

## 2.0.0 — 2026-04-12 (Chain of Custody v2)

### Breaking

- **Dispatch pattern required**: The shared `LOOPCTL_AGENT_KEY` pattern is
  replaced by per-dispatch ephemeral keys minted via `POST /api/v1/dispatches`.
  After the epic merge, long-lived agent keys without a dispatch association
  will fail with `403 missing_dispatch`.

### Added

- `dispatch` tool wraps `POST /api/v1/dispatches`. Mints ephemeral api_keys
  for sub-agents with bounded TTL and lineage tracking.
- Tool description includes ephemeral key handling instructions.

### Changed

- Version bumped from 1.2.0 to 2.0.0 (semver breaking change).
- All existing tools continue to work unchanged.

---

## 1.2.0 — 2026-04-11

### Added

- `knowledge_search`, `knowledge_get`, `knowledge_context`, `knowledge_index` now accept optional `story_id` (UUID) parameter. When present, forwarded as a query param so the server can attribute the wiki read to the active story. (US-25.3, AC-25.3.1–25.3.4)
- `knowledge_get` also gains optional `project_id` parameter (the other three already had it).
- `knowledge_agent_usage` now accepts `api_key_id` (the `api_keys.id` credential) OR `agent_id` (the `agents.id` logical identity). Passing both is a validation error. Passing neither is a validation error. The tool description explains the difference. (US-25.3, AC-25.3.5)
- When `agent_id` alone is passed to `knowledge_agent_usage`, the response includes `_meta.deprecation_hint` nudging callers toward explicit `api_key_id` for credential lookups. (US-25.3, AC-25.3.6)
- README: new "Wiki Attribution" section explains context params, api_key_id vs agent_id disambiguation, and the deprecation path. Includes example workflow snippets. (US-25.3, AC-25.3.7–25.3.8)
- Test suite bootstrapped at `test/knowledge_tools.test.js` using Node.js built-in `node:test`. Run with `npm test`.

### Changed

- All four wiki read tool descriptions shortened and updated with the one-line nudge: "Pass story_id when working on a loopctl story so reads attribute correctly." (AC-25.3.9)
- `knowledge_agent_usage` description rewritten to explain the new `api_key_id`/`agent_id` split.
- `package.json`: added `"test": "node --test test/"` script.
- Server version string updated to `1.2.0`.

### Deprecated

- `knowledge_agent_usage` with a single `agent_id` parameter (old behavior: `agent_id` meant `api_keys.id` credential). Now `agent_id` refers to the logical `agents.id`. Use `api_key_id` for the credential. A `_meta.deprecation_hint` is included in the response when `agent_id` alone is used. Will be cleaned up in a future release.

## 1.1.2 — prior release

Initial public release. See git history for details.
