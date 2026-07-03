# loopctl-mcp-server

MCP (Model Context Protocol) server for [loopctl](https://loopctl.com) -- structural trust for AI development loops.

Wraps the loopctl REST API into 72 typed MCP tools so AI coding agents (Claude Code, etc.) can interact with loopctl without writing curl commands.

## Installation

```bash
npm install loopctl-mcp-server
```

Or run directly with npx:

```bash
npx loopctl-mcp-server
```

## Configuration

Add to your `.mcp.json` (Claude Code) or equivalent MCP config:

```json
{
  "mcpServers": {
    "loopctl": {
      "command": "npx",
      "args": ["loopctl-mcp-server"],
      "env": {
        "LOOPCTL_SERVER": "https://loopctl.com",
        "LOOPCTL_ORCH_KEY": "lc_your_orchestrator_key",
        "LOOPCTL_AGENT_KEY": "lc_your_agent_key"
      }
    }
  }
}
```

Or if installed locally:

```json
{
  "mcpServers": {
    "loopctl": {
      "command": "node",
      "args": ["node_modules/loopctl-mcp-server/index.js"],
      "env": {
        "LOOPCTL_SERVER": "https://loopctl.com",
        "LOOPCTL_ORCH_KEY": "lc_your_orchestrator_key",
        "LOOPCTL_AGENT_KEY": "lc_your_agent_key"
      }
    }
  }
}
```

## Environment Variables

| Variable | Description | Default |
|---|---|---|
| `LOOPCTL_SERVER` | loopctl server URL | `https://loopctl.com` |
| `LOOPCTL_API_KEY` | Global API key override (if set, always used) | -- |
| `LOOPCTL_ORCH_KEY` | Orchestrator role API key (verify, reject, review, import) | -- |
| `LOOPCTL_AGENT_KEY` | Agent role API key (contract, claim, start, request-review) | -- |
| `LOOPCTL_USER_KEY` | User role API key. Required ONLY for destructive admin tools like `knowledge_bulk_publish`. Leave unset if you don't use those tools. | -- |

Key resolution priority: `LOOPCTL_API_KEY` > tool-specific key > `LOOPCTL_ORCH_KEY`.

## Tools (72)

### Project Tools

| Tool | Description |
|---|---|
| `get_tenant` | Get current tenant info. Use to verify connectivity. |
| `list_projects` | List all projects in the current tenant. |
| `create_project` | Create a new project in the current tenant. |
| `delete_project` | **Requires `LOOPCTL_USER_KEY`.** Delete a project and all of its dependent resources (epics, stories, audit entries). Irreversible — orchestrator role is not sufficient. |
| `get_progress` | Get progress summary for a project, including story counts by status. Pass `include_cost=true` for cost data. |
| `import_stories` | Import stories into a project from a structured payload (Epic 12 import format). Pass `merge: true` to add stories to epics that already exist (otherwise duplicates return 409). For large payloads, use `payload_path` to read JSON from disk instead of passing it inline. |

### Story Tools

| Tool | Description |
|---|---|
| `list_stories` | List stories for a project, optionally filtered by agent_status, verified_status, or epic_id. Pass `include_token_totals=true` for per-story token data. |
| `list_ready_stories` | List stories that are ready to be worked on (contracted, dependencies met). |
| `get_story` | Get full details for a single story by ID. |
| `create_story` | Create a single story inside an existing epic. Use instead of wrapping a story in a bulk import. Accepts either `epic_id` (UUID) or (`project_id` + `epic_number`). |
| `backfill_story` | **Bypasses the review/verify chain.** Marks a story as verified when the work was completed outside loopctl (e.g. before the project was onboarded). Refused for any story with `assigned_agent_id` set — those must go through the normal report → review → verify flow, not backfill. Also refused for already `:verified` or `:rejected` stories. Records provenance (`reason`, `evidence_url`, `pr_number`) in `metadata.backfill` and emits a `story.backfilled` webhook. |
| `get_acceptance_criteria` | List a story's acceptance criteria with each one's verification status. Required: `story_id`. |

### Workflow Tools (agent key)

| Tool | Description |
|---|---|
| `contract_story` | Agent acknowledges a story's acceptance criteria. Transitions pending -> contracted. |
| `claim_story` | Agent claims a contracted story with pessimistic locking. Transitions contracted -> assigned. |
| `start_story` | Agent starts work on a claimed story. Transitions assigned -> implementing. |
| `request_review` | Agent signals implementation is complete and ready for review. |

### Reviewer Tools (orchestrator key)

| Tool | Description |
|---|---|
| `report_story` | Reviewer confirms the implementation is done. Transitions implementing -> reported_done. Accepts optional `token_usage` object. |
| `review_complete` | Record that a review has been completed for a story. Required before verify. |

### Verification Tools (orchestrator key)

| Tool | Description |
|---|---|
| `verify_story` | Orchestrator verifies a reported_done story. Transitions reported_done -> verified. |
| `reject_story` | Orchestrator rejects a story with a reason. |

### Bulk Tools (orchestrator key)

| Tool | Description |
|---|---|
| `bulk_mark_complete` | **Backfill-only.** Bulk-marks pre-existing, never-dispatched stories (pending, unassigned, no dispatch lineage) as complete in a single call. Dispatched stories are refused — they must go through the normal report → review → verify flow. |
| `verify_all_in_epic` | Bulk verify all reported_done, unverified stories in an epic. |

### Token Efficiency Tools

| Tool | Auth Key | Description |
|---|---|---|
| `report_token_usage` | agent | Report input/output token counts, model name, and cost for a story session. Calls `POST /api/v1/token-usage`. |
| `get_cost_summary` | orch | Get cost/token usage summary for a project, optionally broken down by `agent`, `epic`, or `model`. |
| `get_story_token_usage` | orch | Get all token usage records for a single story. |
| `get_cost_anomalies` | orch | Get cost anomaly alerts — stories or agents exceeding expected budgets. Optionally filter by project. |
| `set_token_budget` | orch | Set a token budget (in millicents) for a project, epic, story, or agent scope. Requires orchestrator role. |

### Knowledge Wiki Tools (agent key)

**Which read tool?**

| Need | Use |
|---|---|
| How many articles? (counts only) | `knowledge_stats` |
| Browse the catalog (lightweight id/title/category) | `knowledge_index` |
| Find by topic / relevance (ranked, published-only, lags writes) | `knowledge_search` |
| Enumerate / dedup / repair, or "does X exist?" (full fields, lag-free, all-status) | `knowledge_list` |

| Tool | Description |
|---|---|
| `knowledge_index` | Browse/paginate the knowledge wiki catalog grouped by category. **Agent callers see only articles they own or marked `shared`.** Honors `category`, `tags`, `offset`, `limit` with deterministic ordering over the filtered set (`meta.categories` reports per-category totals within visibility). Use `fields` (default `id,title,category`; request `tags`/`status`/`updated_at` explicitly; `id` and `category` are always included) to keep the payload small. Optional: `project_id`, `story_id`, `category`, `tags`, `offset`, `limit`, `fields`. |
| `knowledge_stats` | Aggregate article counts (`total`, `by_category`, `by_status`) via cheap `COUNT(*) GROUP BY` within agent's visible set — no article metadata loaded. Agent callers see only their own and `shared` articles. Counts span all statuses. Optional: `project_id`. |
| `knowledge_count` | Count articles matching filters **without returning rows** within agent's visible set. Agent callers see only their own and `shared` articles. Same filters as `knowledge_list` (`category`, `status`, `tags`, `match`, `source_type`, `source_id`, `idempotency_key`, `project_id`). With `tags`+`match: all` (+`status`) → "how many published articles tagged both X and Y (that I can see)". Returns `{ count }`. |
| `knowledge_facets` | Count articles grouped by **distinct tag** within agent's visible set, no rows. Agent callers see only their own and `shared` articles. `tag_prefix` (e.g. `book-`) gives the distinct count of a tag family plus per-member totals. Returns `{ data: { tag: count }, meta: { distinct_count } }`. Optional: `category`, `status`, `tags`, `match`, `project_id`, `limit`. |
| `knowledge_search` | Search the knowledge wiki by topic (keyword, semantic, or combined). Returns snippets. **Ranked, published-only, and LAGS writes by minutes while embeddings index — do NOT use for existence/idempotency/dedup checks (a fresh write false-negatives); use `knowledge_list` for that.** `q` is optional when `tags`/`category` are supplied — that **list mode** returns the complete filtered set paginated via `offset`/`limit` over `meta.total_count`. `meta.total_count` is mode-dependent — read `meta.total_count_scope` (`keyword_matches`/`ranked_corpus`/`merged_candidates`/`filtered_set`) and don't use a relevance-mode count to size the wiki (use `knowledge_list` or `knowledge_stats`). Optional: `project_id`, `story_id` for attribution. |
| `knowledge_list` | List articles (`id`, `title`, `category`, `status`, `tags`, `source_type`, `source_id`, `idempotency_key`, timestamps), filtered + paginated. **Body-less summary by default** (safe to page up to `limit=1000`); pass `include_body: true` to also return `body`, in which case the page is bounded by a ~5 MB byte budget — continue via `meta.next_offset` while `meta.has_more`. **Lag-free, all-status** read of the DB of record — unlike `knowledge_search` (ranked, published-only, lags writes) and `knowledge_index` (id/title/category only). The right tool to enumerate/dedup/repair and for idempotency/existence checks: filter by `tags`, `source_type`+`source_id`, or `idempotency_key` and read `meta.total_count` (exact). Single full body → `knowledge_get`; relevant bodies → `knowledge_context`; bulk dump → `knowledge_export`. Optional: `project_id`, `category`, `status`, `tags`, `source_type`, `source_id`, `idempotency_key`, `offset`, `limit`, `include_body`. |
| `knowledge_get` | Get full article content by ID. Use after search to read an article in detail. Optional: `project_id`, `story_id` for attribution. |
| `knowledge_context` | Get relevance-and-recency-ranked full articles for a task query. Best knowledge for your current context. **Agent-memory scoping**: `memory_types` (comma-separated, OR — observation/finding/summary/decision/question/task), `agents` (comma-separated agent_ids, OR), `conversation_id` (exact) filter on article `metadata` (JSONB `@>`). Optional: `project_id`, `story_id` for attribution, `limit`, `recency_weight`. |
| `knowledge_graph` | Multi-hop traversal of the published article-link graph from `article_id` (depth 1–3, default 1), **bounded to agent's visible articles**. Agent callers see only their own and `shared` articles. Bidirectional, cycle-safe, bounded to 100 nodes / 500 edges (`truncated` flags a cap). Returns `nodes` (`id`/`title`/`category`/`depth`) + `edges` (`source_article_id`/`target_article_id`/`relationship_type`). Explore typed connections beyond `knowledge_context`'s 1-hop links. Required: `article_id`. Optional: `depth`, `project_id`. |
| `knowledge_suggest_links` | Ranked typed-link **candidates** for an article by embedding similarity among **visible articles** — **read-only** (creates nothing). Excludes the article itself + any already-linked article (either direction, any type); only embedded published articles visible to the caller. Agent callers see only their own and `shared` articles. Returns `{id, title, category, similarity_score}` highest-first, to create as a **typed** link (relates_to/derived_from/contradicts/supersedes). Required: `article_id`. Optional: `threshold` (cosine floor 0–1, default 0.5), `limit` (default 5). |
| `knowledge_distant_pairs` | Distant-but-bridgeable article pairs in the optimal-novelty embedding band (cosine distance, default 0.3–0.7) — the creative sweet spot. Sampled from **agent's visible published articles**; agent callers see only their own and `shared` articles. `bridge_path: true` requires a ≤2-hop link path. Returns `{a, b, distance}` pairs, paginated. Optional: `min_distance`, `max_distance`, `bridge_path`, `limit` (default 20, max 100), `offset`. |
| `knowledge_novelty` | Score ideas by novelty: embeds each idea's text, returns `novelty_score` = cosine distance to the nearest **visible** prior proposal (0 = identical, higher = more novel, up to 2.0; `null` when the idea text is blank, no visible priors exist, or embedding fails — see `meta.prior_count`). Agent callers see only their own and `shared` articles as priors. Priors default to articles tagged `proposal`. Provide ideas as `texts` (strings) OR `ideas` (strings or objects), ≤50. Optional: `prior_tag`. |
| `knowledge_random_walk` | Random walk through the link graph from `start_id` (no cycles, up to `length` nodes), traversing only **agent's visible published articles**, surfacing unexpected connections. Agent callers see only their own and `shared` articles. Returns `{id, title, category}` in walk order. Required: `start_id`. Optional: `length` (default 4, max 25). |
| `knowledge_conflicts` | List potential-conflict article pairs — published articles flagged "too similar to comfortably coexist" by the auto-linker / nightly lint sweep, highest-overlap first. The KB only FLAGS the pair; it does NOT decide redundancy-vs-contradiction — that's your call with live context. Each entry has both articles (id/title/status/category) + similarity. Then merge (supersede one, `knowledge_create` the merged article, or PATCH) or reconcile if they genuinely disagree. Paginated with `total_count` in meta. Agent role. Optional: `limit` (default 50, max 1000, clamped), `offset`. |
| `knowledge_resolve_conflict` | Record YOUR verdict on a potential-conflict pair (from `knowledge_conflicts`). Dispositions: `dismiss` (false positive, drops from queue), `supersede` (one wins — pass `authoritative_article_id`; nightly executor links + retires loser, only at `confidence:"high"`, reversible/audited), `merge` (at high confidence an LLM synthesizes both into ONE new DRAFT, sources preserved, never auto-published). Non-destructive at agent role — you record intent, the privileged nightly job executes. Last-write-wins per pair. Required: `source_article_id`, `target_article_id`, `disposition`. Optional: `authoritative_article_id`, `classification`, `evidence`, `confidence`. |
| `knowledge_create` | Create a new knowledge article. File findings, document patterns, or record decisions. **Published immediately by default** (visible per `metadata.visibility` — default `owner` for agent authors, only visible to that agent; `shared` for visibility to all agents) — the response `note` says which outcome occurred. Pass `draft: true` to stage it for later review instead (publish afterwards with `knowledge_publish`). Pass `metadata: {visibility: "shared"}` to make the article visible to other agents; higher roles can set visibility and agent_id explicitly. Pass `idempotency_key` for idempotent capture (re-creating with the same key is a no-op returning the existing article — no partial duplicates). Optional: `category`, `tags`, `project_id`, `draft`, `idempotency_key`, `source_type`, `source_id`, `metadata`. |
| `knowledge_okf_export` | **Requires `LOOPCTL_USER_KEY`.** Export the wiki as a portable OKF (Open Knowledge Format) v0.1 bundle of markdown files. Writes to `out_dir`, or returns `{files, meta}` inline. |
| `knowledge_okf_import` | **Requires `LOOPCTL_USER_KEY`.** Import an OKF v0.1 bundle from a local directory. Creates or (with `merge`) updates articles; tolerates and preserves unknown frontmatter. |

### Knowledge Management Tools (orchestrator key)

| Tool | Description |
|---|---|
| `knowledge_publish` | **Requires `LOOPCTL_ORCH_KEY` (orchestrator role).** Publish an existing draft article, making it visible to all agents. (Note: `knowledge_create` publishes on create by default with no orchestrator key needed — this tool is for publishing a draft staged earlier.) Required: `article_id`. |
| `knowledge_bulk_publish` | **Requires `LOOPCTL_USER_KEY`.** Publish drafts, partial-success style: every valid draft publishes; others are reported per-id as `skipped` (already published — idempotent — or archived/superseded), `not_found`, or `errored`. No 100-id cap (auto-chunked); duplicates ignored; safe to retry. `meta.count` = published; `meta.counts`/`meta.results` give the breakdown. Required: `article_ids` (array). |
| `knowledge_unpublish` | **Requires `LOOPCTL_USER_KEY`.** Revert a published article back to draft (hidden from search/context, not deleted). Required: `article_id`. |
| `knowledge_bulk_unpublish` | **Requires `LOOPCTL_USER_KEY`.** Revert published articles to draft in bulk, partial-success style (mirror of `knowledge_bulk_publish`): per-id `unpublished`/`skipped` (already draft, or archived/superseded)/`not_found`/`errored`. No 100-id cap (auto-chunked, ≤5000); duplicates ignored; safe to retry. Not deleted (re-publish to restore; `knowledge_bulk_delete` to archive). `meta.count`/`meta.counts`/`meta.results` give the breakdown. Required: `article_ids` (array). |
| `knowledge_archive` | **Requires `LOOPCTL_USER_KEY`.** Soft-delete an article (draft or published). Row retained for audit; hidden from all reads. Required: `article_id`. |
| `knowledge_delete` | **Requires `LOOPCTL_USER_KEY`.** Alias for `knowledge_archive` — DELETE verb on the REST API archives under the hood. Required: `article_id`. |
| `knowledge_bulk_delete` | **Requires `LOOPCTL_USER_KEY`.** Bulk archive (default, reversible) or IRREVERSIBLE hard-delete by selector. Provide exactly one selector: `article_ids` (list), `source_type`+`source_id` (every active article from a source), or `tag`+`confirm:true` (every active article with the tag — high blast radius). Default = set-based soft archive (idempotent; `meta.count`=archived, `meta.counts`/`meta.results` give the breakdown; ≤5000). **Dry-run** (`dry_run:true`) mutates nothing, returns `meta.would_affect` (with `hard:true` also a single-use `meta.token`, or `meta.confirm_hash` for oversized selectors). **Hard delete** (irreversible): dry-run with `hard:true` for a token, then call again with `hard:true`+`token` to FK-correctly delete the frozen id-set (links first, access events cascade). |
| `knowledge_drafts` | List draft (unpublished) knowledge articles with pagination. Optional: `limit` (default 20, max 1000 — over-max → 400, no silent clamp), `offset` (default 0), `project_id`. Returns `meta.total_count`. |
| `knowledge_lint` | Run a lint check on the knowledge wiki to identify stale or low-coverage articles. Optional: `project_id`, `stale_days`, `min_coverage`, `max_per_category` (default 50, max 500). True totals returned in `summary.total_per_category`. |
| `knowledge_export` | Export all knowledge articles as an OKF v0.1 bundle (gzipped tar archive, unbounded, bounded-memory streaming, fail-closed). Returns a curl command for direct download — **the download requires `LOOPCTL_USER_KEY`** (an orchestrator key would 403). Pass `format=json` for buffered in-memory JSON (convenience tool for file writers; capped at `export_max_buffered_export_articles` — returns 413 if over-cap). Optional: `project_id`, `format` (`tar.gz` default or `json`). |
| `knowledge_ingest` | Submit a URL or raw content for knowledge extraction. Enqueues an Oban job. Extracted articles are **drafts by default** (lower-trust LLM output); pass `publish: true` to publish on extraction. Required: `source_type`. One of: `url` or `content`. Optional: `project_id`, `publish`. |
| `knowledge_ingest_batch` | Submit up to 50 ingestion items in a single request. Each item has the same shape as `knowledge_ingest` (incl. `publish`). Returns per-item results. Required: `items`. Optional: batch-level `project_id` / `publish` defaults. |
| `knowledge_ingestion_jobs` | List recent content ingestion jobs (last 7 days, max 50). |

### Per-tenant BYO LLM config + usage (Epic 28, #179)

| Tool | Description |
|---|---|
| `llm_config` | Get the tenant's BYO Anthropic LLM config: per-operation models, `has_api_key`, and a masked last-4 hint. Never returns the key. Requires **user** key. |
| `set_llm_config` | Set/rotate the tenant's OWN Anthropic API key (stored encrypted, never returned) + the three per-operation models (`extraction_model`/`classification_model`/`merge_model`). Any subset; omitting `api_key` leaves it untouched. Requires **user** key. |
| `knowledge_llm_usage` | Per-tenant LLM token-usage summary, grouped by operation + model + source_type + day over an optional `from`/`to` range, with `limit`/`offset` pagination. Record-only (no budget enforcement). Requires orchestrator key. |

### Knowledge Analytics Tools (orchestrator key)

| Tool | Description |
|---|---|
| `knowledge_analytics_top` | Top accessed knowledge articles for the tenant. Optional: `limit` (default 20, max 100), `since_days` (default 7), `access_type` (`search`, `get`, `context`, `index`). |
| `knowledge_article_stats` | Per-article usage stats: total accesses, unique agents, by-type breakdown, recent events. Required: `article_id`. |
| `knowledge_agent_usage` | Per-agent knowledge usage: total reads, unique articles, top read articles. Required: exactly one of `api_key_id` (credential) or `agent_id` (logical identity). Optional: `limit`, `since_days`. See Wiki Attribution section. |
| `knowledge_unused_articles` | Published articles with zero accesses in the window. Optional: `days_unused` (default 30), `limit` (default 50, max 200). |
| `knowledge_curation_log` | Concise human-readable log of KB CURATION adjustments — novelty-gate decisions (`gate_duplicate`/`gate_draft`) and conflict resolutions (`supersede`/`merge`/`dismiss`) — for analyzing the agents'-KB rollout, distinct from the verbose audit log. Each entry: `{at, kind, summary, refs, actor, confidence}`. **RECORDED ONLY when `settings.kb_curation_log` is on** (PATCH `/api/v1/admin/tenants/:id` with `settings:{kb_curation_log:true}`); off by default = no rows. Most recent first. Requires orchestrator role. Optional: `kind`, `since` (ISO8601), `limit` (default 50, max 500), `offset`. |
| `knowledge_retrieval_metrics` | Daily retrieval-PRECISION time series: for each day, the share of search results the agent then opened (search → get/context within a window). A proxy for whether retrieval is improving as the corpus is de-duplicated, better navigated (MOCs), and conflict-resolved. Most recent day first. Requires orchestrator role. Optional: `limit` (default 30, max 365), `offset`. |

### Discovery Tools

| Tool | Description |
|---|---|
| `list_routes` | List all available API routes on the loopctl server. |
| `get_system_articles` | List or fetch system-scoped (global, cross-tenant) wiki articles. Public — no auth required. Optional: `slug` (fetch one), `category`. |

### Dispatch & Chain of Custody (v2) Tools

Key distribution for the dispatch pattern (Epic 26): per-dispatch ephemeral keys and capability-token recovery. See `docs/chain-of-custody-v2.md`.

| Tool | Description |
|---|---|
| `dispatch` | Mint an ephemeral, scoped api_key for a sub-agent dispatch, carrying its lineage path. The `raw_key` is returned ONCE — pass it to the sub-agent's launch args, never store it in env vars; it expires after `expires_in_seconds` (default 3600, max 14400). Required: `role` (`agent`/`orchestrator`), `agent_id`. Optional: `parent_dispatch_id`, `story_id`. |
| `recover_cap` | Re-mint a capability token for a story you're assigned to, after a session crash lost your cap. Required: `story_id`. Optional: `cap_type` (`start_cap`/`report_cap`, default `start_cap`), `lineage`. |
| `get_sth` | Get the latest Signed Tree Head for a tenant's tamper-evident audit chain. Public — no auth required. Required: `tenant_id`. |

## Wiki Attribution

### Passing context parameters on wiki reads

Four wiki read tools (`knowledge_search`, `knowledge_get`, `knowledge_context`, `knowledge_index`) accept two optional attribution parameters:

| Parameter | Description |
|---|---|
| `project_id` | UUID of the loopctl project the agent is working on |
| `story_id` | UUID of the loopctl story the agent is currently implementing |

Passing these parameters lets loopctl record which project and story triggered each wiki read. The analytics endpoints (`knowledge_analytics_top`, `knowledge_agent_usage`, etc.) can then slice usage by project, showing which knowledge articles are most valuable per project.

The server silently drops attribution params that belong to a different tenant or are malformed UUIDs — you will not receive an error for invalid values.

**Always pass `story_id` when you are working on a loopctl story.** This is the primary mechanism by which wiki reads are attributed to development work.

#### Example: typical implementation agent workflow

Step 1 — fetch the story to pick up its UUID and context:

```json
{
  "tool": "get_story",
  "arguments": { "story_id": "89aa0c48-5cf5-4925-b164-21684ef79c4d" }
}
```

Step 2 — call `knowledge_search`, passing `story_id` so the read is attributed:

```json
{
  "tool": "knowledge_search",
  "arguments": {
    "q": "csv import bulk validation",
    "project_id": "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0",
    "story_id": "89aa0c48-5cf5-4925-b164-21684ef79c4d"
  }
}
```

Step 3 — call `knowledge_get`, reusing the same `story_id`:

```json
{
  "tool": "knowledge_get",
  "arguments": {
    "article_id": "c3d2e1f0-1234-5678-abcd-ef0123456789",
    "project_id": "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0",
    "story_id": "89aa0c48-5cf5-4925-b164-21684ef79c4d"
  }
}
```

### `knowledge_agent_usage`: api_key_id vs agent_id

The `knowledge_agent_usage` tool accepts **exactly one** of two identifier parameters:

| Parameter | Meaning | When to use |
|---|---|---|
| `api_key_id` | The `api_keys.id` credential UUID — the raw API key identity | You have the credential ID from `GET /api/v1/api_keys` or a loopctl admin page |
| `agent_id` | The `agents.id` logical identity UUID — the agent registry entry | You have the agent registry ID from `GET /api/v1/agents` or a story's `assigned_agent_id` |

The server's analytics endpoint performs dual-resolution: it tries both interpretations automatically. However, using the explicit parameter makes your intent clear and avoids ambiguity in the response's `resolved_as` field.

Passing both parameters returns a validation error. Passing neither also returns a validation error.

```json
// Query by credential (api_key_id)
{
  "tool": "knowledge_agent_usage",
  "arguments": {
    "api_key_id": "b977c90c-061b-4e42-8afa-26a5efde51ad",
    "since_days": 7
  }
}

// Query by logical agent identity (agent_id)
{
  "tool": "knowledge_agent_usage",
  "arguments": {
    "agent_id": "09429bc4-328f-42f4-acec-db48b40849b2",
    "since_days": 30
  }
}
```

#### Deprecated: old `agent_id` behavior

In versions before 1.2.0, `knowledge_agent_usage` accepted a single `agent_id` parameter that actually meant the `api_keys.id` credential (not the logical agent). This was confusing and caused silent zero-result responses when callers passed a logical `agents.id` value.

Starting with 1.2.0:
- `agent_id` means the **logical** `agents.id` (the agent registry entry).
- `api_key_id` means the **credential** `api_keys.id` (the raw API key).
- The old behavior (passing `agent_id` meaning credential) is Deprecated and will be removed in a future release. When you call with `agent_id` alone, the response includes a `_meta.deprecation_hint` nudging you toward explicit parameters.

## Chain-of-Custody Enforcement

loopctl enforces that nobody marks their own work as done. The API returns `409` if the caller's identity matches the story's assigned agent:

- `report_story` -- 409 `self_report_blocked`
- `review_complete` -- 409 `self_review_blocked`
- `verify_story` -- 409 `self_verify_blocked`

The implementer's final action is `request_review`. All subsequent steps (report, review, verify) must come from different agents.

## Troubleshooting

### Connection errors

- Verify `LOOPCTL_SERVER` is set and reachable
- Check that the server URL includes the protocol (`https://`)
- If using a self-signed certificate, set `NODE_TLS_REJECT_UNAUTHORIZED=0` in your environment (not recommended for production)

### Authentication errors (401)

- Verify your API key is correct and active
- Check that the key has the right role for the operation (agent vs orchestrator)
- Keys are prefixed with `lc_` -- ensure the full key is provided

### Permission errors (403)

- Orchestrator operations require an orchestrator-role key
- Agent operations require an agent-role key
- Chain-of-custody violations return 409, not 403

### Tool not found

- Ensure the MCP server is running (`npx loopctl-mcp-server` to test)
- Check your `.mcp.json` configuration syntax
- Restart your AI coding tool after configuration changes

## Links

- [loopctl.com](https://loopctl.com) -- landing page and documentation
- [API docs](https://loopctl.com/swaggerui) -- Swagger UI
- [GitHub](https://github.com/mkreyman/loopctl) -- source code
- [npm](https://www.npmjs.com/package/loopctl-mcp-server) -- npm package

## License

MIT
