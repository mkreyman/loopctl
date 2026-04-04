# loopctl-mcp-server

MCP (Model Context Protocol) server for [loopctl](https://loopctl.com) -- structural trust for AI development loops.

Wraps the loopctl REST API into 24 typed MCP tools so AI coding agents (Claude Code, etc.) can interact with loopctl without writing curl commands.

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

Key resolution priority: `LOOPCTL_API_KEY` > tool-specific key > `LOOPCTL_ORCH_KEY`.

## Tools (24)

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

### Discovery Tools

| Tool | Description |
|---|---|
| `list_routes` | List all available API routes on the loopctl server. |

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
