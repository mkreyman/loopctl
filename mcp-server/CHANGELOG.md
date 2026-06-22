# Changelog

All notable changes to `loopctl-mcp-server` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

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
