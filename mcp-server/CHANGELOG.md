# Changelog

All notable changes to `loopctl-mcp-server` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

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
