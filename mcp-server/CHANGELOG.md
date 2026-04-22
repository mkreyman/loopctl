# Changelog

All notable changes to `loopctl-mcp-server` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

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
