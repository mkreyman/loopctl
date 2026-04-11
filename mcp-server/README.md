# loopctl-mcp-server

MCP (Model Context Protocol) server for [loopctl](https://loopctl.com) -- structural trust for AI development loops.

Wraps the loopctl REST API into 41 typed MCP tools so AI coding agents (Claude Code, etc.) can interact with loopctl without writing curl commands.

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

## Tools (41)

### Project Tools

| Tool | Description |
|---|---|
| `get_tenant` | Get current tenant info. Use to verify connectivity. |
| `list_projects` | List all projects in the current tenant. |
| `create_project` | Create a new project in the current tenant. |
| `get_progress` | Get progress summary for a project, including story counts by status. Pass `include_cost=true` for cost data. |
| `import_stories` | Import stories into a project from a structured payload (Epic 12 import format). |

### Story Tools

| Tool | Description |
|---|---|
| `list_stories` | List stories for a project, optionally filtered by agent_status, verified_status, or epic_id. Pass `include_token_totals=true` for per-story token data. |
| `list_ready_stories` | List stories that are ready to be worked on (contracted, dependencies met). |
| `get_story` | Get full details for a single story by ID. |

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
| `bulk_mark_complete` | Bulk mark multiple stories as complete in a single API call. |
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

| Tool | Description |
|---|---|
| `knowledge_index` | Load the knowledge wiki catalog at session start. Returns lightweight article metadata grouped by category. Optional: `project_id`, `story_id`. |
| `knowledge_search` | Search the knowledge wiki by topic. Supports keyword, semantic, or combined search modes. Returns snippets. Optional: `project_id`, `story_id` for attribution. |
| `knowledge_get` | Get full article content by ID. Use after search to read an article in detail. Optional: `project_id`, `story_id` for attribution. |
| `knowledge_context` | Get relevance-and-recency-ranked full articles for a task query. Best knowledge for your current context. Optional: `project_id`, `story_id` for attribution. |
| `knowledge_create` | Create a new knowledge article. File findings, document patterns, or record decisions. |

### Knowledge Management Tools (orchestrator key)

| Tool | Description |
|---|---|
| `knowledge_publish` | Publish a draft article, making it visible to all agents. Required: `article_id`. |
| `knowledge_bulk_publish` | **Requires `LOOPCTL_USER_KEY`.** Atomically publish up to 100 drafts in a single call. Required: `article_ids` (array). |
| `knowledge_drafts` | List draft (unpublished) knowledge articles with pagination. Optional: `limit` (default 20, max 20), `offset` (default 0), `project_id`. Returns `meta.total_count`. |
| `knowledge_lint` | Run a lint check on the knowledge wiki to identify stale or low-coverage articles. Optional: `project_id`, `stale_days`, `min_coverage`, `max_per_category` (default 50, max 500). True totals returned in `summary.total_per_category`. |
| `knowledge_export` | Export all knowledge articles as a ZIP archive. Returns a curl command for direct download (ZIP binary cannot be returned as MCP content). Optional: `project_id`. |
| `knowledge_ingest` | Submit a URL or raw content for knowledge extraction. Enqueues an Oban job. Required: `source_type`. One of: `url` or `content`. Optional: `project_id`. |
| `knowledge_ingest_batch` | Submit up to 50 ingestion items in a single request. Each item has the same shape as `knowledge_ingest`. Returns per-item results. Required: `items`. Optional: batch-level `project_id` default. |
| `knowledge_ingestion_jobs` | List recent content ingestion jobs (last 7 days, max 50). |

### Knowledge Analytics Tools (orchestrator key)

| Tool | Description |
|---|---|
| `knowledge_analytics_top` | Top accessed knowledge articles for the tenant. Optional: `limit` (default 20, max 100), `since_days` (default 7), `access_type` (`search`, `get`, `context`, `index`). |
| `knowledge_article_stats` | Per-article usage stats: total accesses, unique agents, by-type breakdown, recent events. Required: `article_id`. |
| `knowledge_agent_usage` | Per-agent knowledge usage: total reads, unique articles, top read articles. Required: exactly one of `api_key_id` (credential) or `agent_id` (logical identity). Optional: `limit`, `since_days`. See Wiki Attribution section. |
| `knowledge_unused_articles` | Published articles with zero accesses in the window. Optional: `days_unused` (default 30), `limit` (default 50, max 200). |

### Discovery Tools

| Tool | Description |
|---|---|
| `list_routes` | List all available API routes on the loopctl server. |

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

```json
// Step 1: get_story to retrieve current story context
{
  "tool": "get_story",
  "arguments": { "story_id": "89aa0c48-5cf5-4925-b164-21684ef79c4d" }
}

// Step 2: knowledge_search — pass story_id so the read is attributed
{
  "tool": "knowledge_search",
  "arguments": {
    "q": "csv import bulk validation",
    "project_id": "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0",
    "story_id": "89aa0c48-5cf5-4925-b164-21684ef79c4d"
  }
}

// Step 3: knowledge_get — pass story_id again for the full article read
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
| `api_key_id` | The `api_keys.id` credential UUID — the raw API key identity | You have the credential ID from `list_api_keys` or a loopctl admin page |
| `agent_id` | The `agents.id` logical identity UUID — the agent registry entry | You have the agent registry ID from `list_agents` or a story's `assigned_agent_id` |

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
