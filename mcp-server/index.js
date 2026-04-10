#!/usr/bin/env node

// loopctl MCP Server
// Wraps the loopctl REST API into typed MCP tools for Claude Code agents.
// Runs via stdio (stdin/stdout).

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------

function getBaseUrl() {
  return (process.env.LOOPCTL_SERVER || "https://loopctl.com").replace(/\/$/, "");
}

/**
 * Resolve which API key to use for a request.
 *
 * Priority:
 *  1. LOOPCTL_API_KEY (global override — if set, always used)
 *  2. keyOverride passed by the tool function (role-specific key)
 *  3. LOOPCTL_ORCH_KEY (safe default for reads)
 */
function resolveKey(keyOverride) {
  return (
    process.env.LOOPCTL_API_KEY ||
    keyOverride ||
    process.env.LOOPCTL_ORCH_KEY
  );
}

async function apiCall(method, path, body, keyOverride) {
  const url = `${getBaseUrl()}${path}`;
  const key = resolveKey(keyOverride);

  if (!key) {
    return { error: true, status: 0, body: "No API key configured. Set LOOPCTL_API_KEY, LOOPCTL_ORCH_KEY, or LOOPCTL_AGENT_KEY." };
  }

  const options = {
    method,
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    signal: AbortSignal.timeout(30_000),
  };

  if (body !== undefined && body !== null) {
    options.body = JSON.stringify(body);
  }

  let response;
  try {
    response = await fetch(url, options);
  } catch (err) {
    if (err.name === "TimeoutError") {
      return { error: true, status: 0, body: "Request timed out after 30s" };
    }
    const cause = err.cause?.message ? ` (${err.cause.message})` : "";
    return { error: true, status: 0, body: `Network error: ${err.message}${cause}` };
  }

  if (response.status === 204) {
    return { ok: true };
  }

  let responseBody;
  const contentType = response.headers.get("content-type") || "";
  if (contentType.includes("application/json")) {
    responseBody = await response.json();
  } else {
    const text = await response.text();
    try {
      responseBody = JSON.parse(text);
    } catch {
      responseBody = text;
    }
  }

  if (!response.ok) {
    let errorBody = responseBody;
    if (typeof errorBody === "string" && errorBody.length > 500) {
      errorBody = errorBody
        .replace(/<[^>]+>/g, " ")
        .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
        .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, " ")
        .replace(/\s+/g, " ")
        .trim()
        .slice(0, 500) + "... (truncated)";
    }
    return { error: true, status: response.status, body: errorBody };
  }

  return responseBody;
}

function toContent(result) {
  const isErr = result && result.error === true;
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(result, null, 2),
      },
    ],
    ...(isErr && { isError: true }),
  };
}

/**
 * Compact variant for list endpoints — strips acceptance_criteria and
 * description (use get_story for full details). Keeps all other fields.
 * Enforces a max page size to prevent MCP response token overflow.
 */
const MAX_PAGE_SIZE = 20;

function toContentCompact(result) {
  if (result && result.error === true) return toContent(result);

  if (result && Array.isArray(result.data)) {
    const compact = {
      ...result,
      data: result.data.map(({ acceptance_criteria, description, ...rest }) => rest),
    };
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(compact, null, 2),
        },
      ],
    };
  }

  return toContent(result);
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

// --- Project Tools ---

async function getTenant() {
  const result = await apiCall("GET", "/api/v1/tenants/me");
  return toContent(result);
}

async function listProjects() {
  const result = await apiCall("GET", "/api/v1/projects");
  return toContent(result);
}

async function createProject({ name, slug, repo_url, description, tech_stack }) {
  const body = { name, slug };
  if (repo_url) body.repo_url = repo_url;
  if (description) body.description = description;
  if (tech_stack) body.tech_stack = tech_stack;
  const result = await apiCall("POST", "/api/v1/projects", body, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function getProgress({ project_id, include_cost }) {
  const params = new URLSearchParams();
  if (include_cost) params.set("include_cost", "true");
  const query = params.toString() ? `?${params}` : "";
  const result = await apiCall("GET", `/api/v1/projects/${project_id}/progress${query}`);
  return toContent(result);
}

async function importStories({ project_id, payload }) {
  const result = await apiCall(
    "POST",
    `/api/v1/projects/${project_id}/import`,
    payload,
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

// --- Story Tools ---

async function listStories({ project_id, agent_status, verified_status, epic_id, limit, offset, include_token_totals }) {
  const params = new URLSearchParams({ project_id });
  if (agent_status) params.set("agent_status", agent_status);
  if (verified_status) params.set("verified_status", verified_status);
  if (epic_id) params.set("epic_id", epic_id);
  params.set("limit", String(Math.min(limit ?? MAX_PAGE_SIZE, MAX_PAGE_SIZE)));
  if (offset != null) params.set("offset", String(offset));
  if (include_token_totals) params.set("include_token_totals", "true");

  const result = await apiCall("GET", `/api/v1/stories?${params}`);
  return toContentCompact(result);
}

async function listReadyStories({ project_id, limit }) {
  const params = new URLSearchParams({ project_id });
  params.set("limit", String(Math.min(limit ?? MAX_PAGE_SIZE, MAX_PAGE_SIZE)));

  const result = await apiCall("GET", `/api/v1/stories/ready?${params}`);
  return toContentCompact(result);
}

async function getStory({ story_id }) {
  const result = await apiCall("GET", `/api/v1/stories/${story_id}`);
  return toContent(result);
}

// --- Workflow Tools (agent key) ---

async function contractStory({ story_id, story_title, ac_count }) {
  const result = await apiCall(
    "POST",
    `/api/v1/stories/${story_id}/contract`,
    { story_title, ac_count },
    process.env.LOOPCTL_AGENT_KEY
  );
  return toContent(result);
}

async function claimStory({ story_id }) {
  const result = await apiCall(
    "POST",
    `/api/v1/stories/${story_id}/claim`,
    null,
    process.env.LOOPCTL_AGENT_KEY
  );
  return toContent(result);
}

async function startStory({ story_id }) {
  const result = await apiCall(
    "POST",
    `/api/v1/stories/${story_id}/start`,
    null,
    process.env.LOOPCTL_AGENT_KEY
  );
  return toContent(result);
}

async function requestReview({ story_id }) {
  const result = await apiCall(
    "POST",
    `/api/v1/stories/${story_id}/request-review`,
    null,
    process.env.LOOPCTL_AGENT_KEY
  );
  return toContent(result);
}

// --- Reviewer Tools (orch key — reviewer uses orchestrator role) ---

async function reportStory({ story_id, artifact_type, artifact_path, token_usage }) {
  const body = {};
  if (artifact_type || artifact_path) {
    body.artifact = {};
    if (artifact_type) body.artifact.artifact_type = artifact_type;
    if (artifact_path) body.artifact.path = artifact_path;
  }
  if (token_usage) {
    body.token_usage = token_usage;
  }

  const result = await apiCall(
    "POST",
    `/api/v1/stories/${story_id}/report`,
    Object.keys(body).length > 0 ? body : null,
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

async function reviewComplete({ story_id, review_type, findings_count, fixes_count, disproved_count, summary }) {
  const body = { review_type };
  if (findings_count != null) body.findings_count = findings_count;
  if (fixes_count != null) body.fixes_count = fixes_count;
  if (disproved_count != null) body.disproved_count = disproved_count;
  if (summary) body.summary = summary;

  const result = await apiCall(
    "POST",
    `/api/v1/stories/${story_id}/review-complete`,
    body,
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

// --- Verification Tools (orch key) ---

async function verifyStory({ story_id, summary, review_type }) {
  const body = {};
  if (summary) body.summary = summary;
  if (review_type) body.review_type = review_type;

  const result = await apiCall(
    "POST",
    `/api/v1/stories/${story_id}/verify`,
    body,
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

async function rejectStory({ story_id, reason }) {
  const result = await apiCall(
    "POST",
    `/api/v1/stories/${story_id}/reject`,
    { reason },
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

// --- Bulk Tools ---

async function bulkMarkComplete({ stories }) {
  // stories: [{story_id, summary, review_type}]
  const result = await apiCall(
    "POST",
    "/api/v1/stories/bulk/mark-complete",
    { stories },
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

async function verifyAllInEpic({ epic_id, review_type, summary }) {
  const result = await apiCall(
    "POST",
    `/api/v1/epics/${epic_id}/verify-all`,
    { review_type, summary },
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

// --- Token Efficiency Tools ---

async function reportTokenUsage({ story_id, input_tokens, output_tokens, model_name, cost_millicents, phase, skill_version_id, session_id }) {
  const body = { story_id, input_tokens, output_tokens, model_name, cost_millicents };
  if (phase) body.phase = phase;
  if (skill_version_id) body.skill_version_id = skill_version_id;
  if (session_id) body.session_id = session_id;

  const result = await apiCall(
    "POST",
    "/api/v1/token-usage",
    body,
    process.env.LOOPCTL_AGENT_KEY
  );
  return toContent(result);
}

async function getCostSummary({ project_id, breakdown }) {
  let path;
  if (breakdown === "agent") {
    path = `/api/v1/analytics/agents?project_id=${project_id}`;
  } else if (breakdown === "epic") {
    path = `/api/v1/analytics/epics?project_id=${project_id}`;
  } else if (breakdown === "model") {
    path = `/api/v1/analytics/models?project_id=${project_id}`;
  } else {
    path = `/api/v1/analytics/projects/${project_id}`;
  }

  const result = await apiCall("GET", path);
  return toContent(result);
}

async function getStoryTokenUsage({ story_id }) {
  const result = await apiCall("GET", `/api/v1/stories/${story_id}/token-usage`);
  return toContent(result);
}

async function getCostAnomalies({ project_id }) {
  const params = new URLSearchParams();
  if (project_id) params.set("project_id", project_id);

  const query = params.toString() ? `?${params}` : "";
  const result = await apiCall("GET", `/api/v1/cost-anomalies${query}`);
  return toContent(result);
}

async function setTokenBudget({ scope_type, scope_id, budget_millicents, alert_threshold_pct }) {
  const body = { scope_type, scope_id, budget_millicents };
  if (alert_threshold_pct != null) body.alert_threshold_pct = alert_threshold_pct;

  const result = await apiCall(
    "POST",
    "/api/v1/token-budgets",
    body,
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

// --- Knowledge Wiki Tools (agent key) ---

async function knowledgeIndex({ project_id }) {
  const path = project_id
    ? `/api/v1/projects/${project_id}/knowledge/index`
    : "/api/v1/knowledge/index";
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeSearch({ q, project_id, category, tags, mode, limit }) {
  const params = new URLSearchParams({ q });
  if (project_id) params.set("project_id", project_id);
  if (category) params.set("category", category);
  if (tags) params.set("tags", tags);
  if (mode) params.set("mode", mode);
  if (limit != null) params.set("limit", String(limit));

  const result = await apiCall("GET", `/api/v1/knowledge/search?${params}`, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeGet({ article_id }) {
  const result = await apiCall("GET", `/api/v1/articles/${article_id}`, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeContext({ query, project_id, limit, recency_weight }) {
  const params = new URLSearchParams({ query });
  if (project_id) params.set("project_id", project_id);
  if (limit != null) params.set("limit", String(limit));
  if (recency_weight != null) params.set("recency_weight", String(recency_weight));

  const result = await apiCall("GET", `/api/v1/knowledge/context?${params}`, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeCreate({ title, body, category, tags, project_id }) {
  const payload = { title, body };
  if (category) payload.category = category;
  if (tags) payload.tags = tags;
  if (project_id) payload.project_id = project_id;

  const result = await apiCall("POST", "/api/v1/articles", payload, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

// --- Knowledge Management Tools (orch key) ---

async function knowledgePublish({ article_id }) {
  const result = await apiCall("POST", `/api/v1/articles/${article_id}/publish`, null, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function knowledgeDrafts({ limit, offset }) {
  const params = new URLSearchParams();
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  const qs = params.toString();
  const path = qs ? `/api/v1/knowledge/drafts?${qs}` : "/api/v1/knowledge/drafts";
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function knowledgeLint({ project_id, stale_days, min_coverage }) {
  const params = new URLSearchParams();
  if (stale_days != null) params.set("stale_days", String(stale_days));
  if (min_coverage != null) params.set("min_coverage", String(min_coverage));
  const qs = params.toString();
  const basePath = project_id
    ? `/api/v1/projects/${project_id}/knowledge/lint`
    : "/api/v1/knowledge/lint";
  const path = qs ? `${basePath}?${qs}` : basePath;
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function knowledgeExport({ project_id }) {
  const basePath = project_id
    ? `/api/v1/projects/${project_id}/knowledge/export`
    : "/api/v1/knowledge/export";
  const baseUrl = getBaseUrl();
  const downloadCmd = `curl -H "Authorization: Bearer $LOOPCTL_ORCH_KEY" "${baseUrl}${basePath}" -o knowledge-export.zip`;
  return {
    content: [{
      type: "text",
      text: JSON.stringify({
        message: "Knowledge export produces a ZIP file. Use the curl command below to download it directly.",
        command: downloadCmd,
        endpoint: `${baseUrl}${basePath}`,
      }, null, 2),
    }],
  };
}

// --- Discovery Tools ---

async function listRoutes() {
  const result = await apiCall("GET", "/api/v1/routes");
  return toContent(result);
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

const TOOLS = [
  // Project Tools
  {
    name: "get_tenant",
    description: "Get current tenant info. Use to verify connectivity.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
  {
    name: "list_projects",
    description: "List all projects in the current tenant.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
  {
    name: "create_project",
    description: "Create a new project in the current tenant.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Project name." },
        slug: { type: "string", description: "URL-safe slug." },
        repo_url: { type: "string", description: "GitHub repo URL." },
        description: { type: "string", description: "Project description." },
        tech_stack: { type: "string", description: "Tech stack summary." },
      },
      required: ["name", "slug"],
    },
  },
  {
    name: "get_progress",
    description: "Get progress summary for a project, including story counts by status. Pass include_cost=true to include cost data when available.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "The UUID of the project.",
        },
        include_cost: {
          type: "boolean",
          description: "Optional: include cost/token summary data in the response.",
        },
      },
      required: ["project_id"],
    },
  },
  {
    name: "import_stories",
    description: "Import stories into a project from a structured payload (Epic 12 import format).",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "The UUID of the project to import into.",
        },
        payload: {
          type: "object",
          description: "The import payload object (epics + stories structure).",
        },
      },
      required: ["project_id", "payload"],
    },
  },

  // Story Tools
  {
    name: "list_stories",
    description:
      "List stories for a project, optionally filtered by agent_status, verified_status, or epic_id. " +
      "Returns compact results (no acceptance_criteria/description) — use get_story for full details. " +
      "Max 20 per page. Use offset to paginate (response includes total_count). " +
      "Filter by epic_id or agent_status to reduce result size.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "The UUID of the project.",
        },
        agent_status: {
          type: "string",
          description:
            "Filter by agent status (e.g. pending, contracted, assigned, implementing, reported_done, verified, rejected).",
        },
        verified_status: {
          type: "string",
          description: "Filter by verified status (e.g. unverified, verified, rejected).",
        },
        epic_id: {
          type: "string",
          description: "Filter by epic UUID.",
        },
        limit: {
          type: "integer",
          description: "Maximum number of stories to return.",
        },
        offset: {
          type: "integer",
          description: "Number of stories to skip (for pagination).",
        },
        include_token_totals: {
          type: "boolean",
          description: "Optional: include per-story token usage totals when available.",
        },
      },
      required: ["project_id"],
    },
  },
  {
    name: "list_ready_stories",
    description:
      "List stories that are ready to be worked on (contracted, dependencies met). " +
      "Returns compact results — use get_story for full details. " +
      "Max 20 per page. Response includes total_count for pagination.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "The UUID of the project.",
        },
        limit: {
          type: "integer",
          description: "Maximum number of stories to return.",
        },
      },
      required: ["project_id"],
    },
  },
  {
    name: "get_story",
    description: "Get full details for a single story by ID.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story.",
        },
      },
      required: ["story_id"],
    },
  },

  // Workflow Tools (agent)
  {
    name: "contract_story",
    description:
      "Agent acknowledges a story's acceptance criteria to claim the contract. " +
      "Transitions the story from pending to contracted. " +
      "story_title and ac_count must match the actual story to prevent silent misclaims.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story.",
        },
        story_title: {
          type: "string",
          description: "Must match the story's title exactly (anti-confusion check).",
        },
        ac_count: {
          type: "integer",
          description: "Must match the number of acceptance criteria in the story.",
        },
      },
      required: ["story_id", "story_title", "ac_count"],
    },
  },
  {
    name: "claim_story",
    description:
      "Agent claims a contracted story. Uses pessimistic locking to prevent double-claims. " +
      "Transitions contracted -> assigned. Uses the AGENT key.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story.",
        },
      },
      required: ["story_id"],
    },
  },
  {
    name: "start_story",
    description:
      "Agent starts work on a claimed story. Transitions assigned -> implementing. Uses the AGENT key.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story.",
        },
      },
      required: ["story_id"],
    },
  },
  {
    name: "request_review",
    description:
      "Agent signals that implementation is complete and ready for review. " +
      "Does NOT change the story status — fires a webhook event for the reviewer. Uses the AGENT key.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story.",
        },
      },
      required: ["story_id"],
    },
  },

  // Reviewer Tools (orch key)
  {
    name: "report_story",
    description:
      "Reviewer (a DIFFERENT agent from the implementer) confirms the implementation is done. " +
      "Chain-of-custody: the implementing agent cannot call this. " +
      "Transitions implementing -> reported_done. Uses the ORCH key.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story.",
        },
        artifact_type: {
          type: "string",
          description: "Optional: type of artifact being reported (e.g. branch, pr, test_run).",
        },
        artifact_path: {
          type: "string",
          description: "Optional: path or URL of the artifact.",
        },
        token_usage: {
          type: "object",
          description: "Optional: token usage summary for the implementation work.",
          properties: {
            input_tokens: { type: "integer", description: "Total input tokens consumed." },
            output_tokens: { type: "integer", description: "Total output tokens consumed." },
            model_name: { type: "string", description: "Model name (e.g. claude-sonnet-4-5)." },
            cost_millicents: { type: "integer", description: "Total cost in millicents (1/1000 of a cent)." },
          },
        },
      },
      required: ["story_id"],
    },
  },
  {
    name: "review_complete",
    description:
      "Record that a review has been completed for a story. " +
      "Must be called before verify_story. Uses the ORCH key.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story.",
        },
        review_type: {
          type: "string",
          description:
            "The type of review conducted (e.g. enhanced_6_agent, single_reviewer, orchestrator).",
        },
        findings_count: {
          type: "integer",
          description: "Optional: number of findings from the review.",
        },
        fixes_count: {
          type: "integer",
          description: "Number of fixes applied. fixes_count + disproved_count must equal findings_count.",
        },
        disproved_count: {
          type: "integer",
          description: "Number of findings disproved as false positives. fixes_count + disproved_count must equal findings_count.",
        },
        summary: {
          type: "string",
          description: "Optional: summary of the review outcome.",
        },
      },
      required: ["story_id", "review_type"],
    },
  },

  // Verification Tools (orch key)
  {
    name: "verify_story",
    description:
      "Orchestrator verifies a reported_done story. " +
      "Requires a review_record to exist (call review_complete first). " +
      "Transitions reported_done -> verified. Uses the ORCH key.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story.",
        },
        summary: {
          type: "string",
          description: "Optional: verification summary.",
        },
        review_type: {
          type: "string",
          description: "Optional: review type for the verification record.",
        },
      },
      required: ["story_id"],
    },
  },
  {
    name: "reject_story",
    description:
      "Orchestrator rejects a story with a reason. " +
      "Creates a verification_result with result=fail. Uses the ORCH key.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story.",
        },
        reason: {
          type: "string",
          description: "Required: the reason for rejection.",
        },
      },
      required: ["story_id", "reason"],
    },
  },

  // Bulk Tools
  {
    name: "bulk_mark_complete",
    description:
      "Bulk mark multiple stories as complete in a single API call. " +
      "Each story entry needs a story_id, summary, and review_type. Uses the ORCH key.",
    inputSchema: {
      type: "object",
      properties: {
        stories: {
          type: "array",
          description: "Array of stories to mark complete.",
          items: {
            type: "object",
            properties: {
              story_id: {
                type: "string",
                description: "The UUID of the story.",
              },
              summary: {
                type: "string",
                description: "Summary of the completion.",
              },
              review_type: {
                type: "string",
                description: "Review type used.",
              },
            },
            required: ["story_id", "summary", "review_type"],
          },
        },
      },
      required: ["stories"],
    },
  },
  {
    name: "verify_all_in_epic",
    description:
      "Bulk verify all reported_done, unverified stories in an epic. " +
      "Convenience endpoint for the orchestrator after a review pass. Uses the ORCH key.",
    inputSchema: {
      type: "object",
      properties: {
        epic_id: {
          type: "string",
          description: "The UUID of the epic.",
        },
        review_type: {
          type: "string",
          description: "The review type applied to all stories (e.g. enhanced_6_agent).",
        },
        summary: {
          type: "string",
          description: "Summary of the review/verification pass.",
        },
      },
      required: ["epic_id", "review_type", "summary"],
    },
  },

  // Token Efficiency Tools
  {
    name: "report_token_usage",
    description:
      "Report token usage for a story implementation session. " +
      "Stores input/output token counts, model name, and cost. Uses the AGENT key.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story this usage is attributed to.",
        },
        input_tokens: {
          type: "integer",
          description: "Number of input (prompt) tokens consumed.",
        },
        output_tokens: {
          type: "integer",
          description: "Number of output (completion) tokens consumed.",
        },
        model_name: {
          type: "string",
          description: "Name of the model used (e.g. claude-sonnet-4-5, gpt-4o).",
        },
        cost_millicents: {
          type: "integer",
          description: "Total cost in millicents (1/1000 of a cent).",
        },
        phase: {
          type: "string",
          enum: ["planning", "implementing", "reviewing", "other"],
          description: "Optional: phase of work.",
        },
        skill_version_id: {
          type: "string",
          description: "Optional: UUID of the skill version used.",
        },
        session_id: {
          type: "string",
          description: "Optional: agent session identifier for grouping records.",
        },
      },
      required: ["story_id", "input_tokens", "output_tokens", "model_name", "cost_millicents"],
    },
  },
  {
    name: "get_cost_summary",
    description:
      "Get cost/token usage summary for a project. " +
      "Optionally break down by agent, epic, or model.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "The UUID of the project.",
        },
        breakdown: {
          type: "string",
          enum: ["agent", "epic", "model"],
          description: "Optional: dimension to group the summary by (agent, epic, or model).",
        },
      },
      required: ["project_id"],
    },
  },
  {
    name: "get_story_token_usage",
    description: "Get token usage records for a single story.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story.",
        },
      },
      required: ["story_id"],
    },
  },
  {
    name: "get_cost_anomalies",
    description:
      "Get cost anomaly alerts — stories or agents that exceed expected token budgets. " +
      "Optionally filter by project.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "Optional: filter anomalies to a specific project UUID.",
        },
      },
      required: [],
    },
  },
  {
    name: "set_token_budget",
    description:
      "Set a token budget for a scope (project, epic, story, or agent). " +
      "Requires orchestrator or user role. Uses the ORCH key.",
    inputSchema: {
      type: "object",
      properties: {
        scope_type: {
          type: "string",
          enum: ["project", "epic", "story", "agent"],
          description: "The type of scope to apply the budget to.",
        },
        scope_id: {
          type: "string",
          description: "The UUID of the scoped resource (project_id, epic_id, story_id, or agent_id).",
        },
        budget_millicents: {
          type: "integer",
          description: "Maximum allowed cost in millicents (1/1000 of a cent).",
        },
        alert_threshold_pct: {
          type: "number",
          description: "Optional: percentage of budget at which to trigger an alert (0–100).",
          minimum: 0,
          maximum: 100,
        },
      },
      required: ["scope_type", "scope_id", "budget_millicents"],
    },
  },

  // Knowledge Wiki Tools (agent key)
  {
    name: "knowledge_index",
    description:
      "Load the knowledge wiki catalog at session start. Returns lightweight article metadata " +
      "(titles, categories, tags) grouped by category. Use this to discover available knowledge before searching.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "Optional: scope the index to a specific project UUID.",
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_search",
    description:
      "Search the knowledge wiki by topic. Supports keyword, semantic, or combined search modes. " +
      "Returns snippets, not full bodies. Use after index to find specific articles.",
    inputSchema: {
      type: "object",
      properties: {
        q: {
          type: "string",
          description: "Search query string.",
        },
        project_id: {
          type: "string",
          description: "Optional: scope search to a specific project UUID.",
        },
        category: {
          type: "string",
          description: "Optional: filter results by category.",
        },
        tags: {
          type: "string",
          description: "Optional: comma-separated tags to filter by.",
        },
        mode: {
          type: "string",
          enum: ["keyword", "semantic", "combined"],
          description: "Optional: search mode (keyword, semantic, or combined).",
        },
        limit: {
          type: "integer",
          description: "Optional: maximum number of results to return.",
        },
      },
      required: ["q"],
    },
  },
  {
    name: "knowledge_get",
    description:
      "Get full article content by ID. Use after search to read an article in detail.",
    inputSchema: {
      type: "object",
      properties: {
        article_id: {
          type: "string",
          description: "The UUID of the article.",
        },
      },
      required: ["article_id"],
    },
  },
  {
    name: "knowledge_context",
    description:
      "Get relevance-and-recency-ranked full articles for a task query. Returns the best knowledge " +
      "for your current context with linked references. Use when starting a task that needs domain knowledge.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "The task or topic query to find relevant knowledge for.",
        },
        project_id: {
          type: "string",
          description: "Optional: scope context to a specific project UUID.",
        },
        limit: {
          type: "integer",
          description: "Optional: maximum number of articles to return.",
        },
        recency_weight: {
          type: "number",
          description: "Optional: weight for recency scoring (0.0-1.0).",
          minimum: 0,
          maximum: 1,
        },
      },
      required: ["query"],
    },
  },
  {
    name: "knowledge_create",
    description:
      "Create a new knowledge article. Use to file findings, document patterns, or record decisions " +
      "discovered during implementation.",
    inputSchema: {
      type: "object",
      properties: {
        title: {
          type: "string",
          description: "Article title.",
        },
        body: {
          type: "string",
          description: "Article body content (Markdown supported).",
        },
        category: {
          type: "string",
          description: "Optional: article category.",
        },
        tags: {
          type: "array",
          items: { type: "string" },
          description: "Optional: list of tags.",
        },
        project_id: {
          type: "string",
          description: "Optional: associate the article with a project UUID.",
        },
      },
      required: ["title", "body"],
    },
  },

  // Knowledge Management Tools (orchestrator key)
  {
    name: "knowledge_publish",
    description:
      "Publish a draft knowledge article, making it visible to all agents. Requires orchestrator role.",
    inputSchema: {
      type: "object",
      properties: {
        article_id: {
          type: "string",
          description: "The UUID of the draft article to publish.",
        },
      },
      required: ["article_id"],
    },
  },
  {
    name: "knowledge_drafts",
    description:
      "List all draft (unpublished) knowledge articles. Requires orchestrator role. Use to review pending articles before publishing.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "integer",
          description: "Optional: maximum number of drafts to return.",
        },
        offset: {
          type: "integer",
          description: "Optional: pagination offset.",
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_lint",
    description:
      "Run a lint check on the knowledge wiki to identify stale, low-coverage, or broken articles. " +
      "Requires orchestrator role. Optionally scoped to a project.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "Optional: scope lint to a specific project UUID.",
        },
        stale_days: {
          type: "integer",
          description: "Optional: flag articles not updated in this many days as stale.",
        },
        min_coverage: {
          type: "number",
          description: "Optional: minimum required coverage score (0.0-1.0) to flag under-covered articles.",
          minimum: 0,
          maximum: 1,
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_export",
    description:
      "Export all knowledge articles as a ZIP archive. Because ZIP binary cannot be returned as MCP content, " +
      "this tool returns a curl command you can run directly to download the archive.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "Optional: scope export to a specific project UUID.",
        },
      },
      required: [],
    },
  },

  // Discovery Tools
  {
    name: "list_routes",
    description: "List all available API routes on the loopctl server.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
];

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------

const server = new Server(
  {
    name: "loopctl",
    version: "1.1.2",
  },
  {
    capabilities: { tools: {} },
  }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    // Project Tools
    case "get_tenant":
      return await getTenant();

    case "list_projects":
      return await listProjects();

    case "create_project":
      return await createProject(args);

    case "get_progress":
      return await getProgress(args);

    case "import_stories":
      return await importStories(args);

    // Story Tools
    case "list_stories":
      return await listStories(args);

    case "list_ready_stories":
      return await listReadyStories(args);

    case "get_story":
      return await getStory(args);

    // Workflow Tools
    case "contract_story":
      return await contractStory(args);

    case "claim_story":
      return await claimStory(args);

    case "start_story":
      return await startStory(args);

    case "request_review":
      return await requestReview(args);

    // Reviewer Tools
    case "report_story":
      return await reportStory(args);

    case "review_complete":
      return await reviewComplete(args);

    // Verification Tools
    case "verify_story":
      return await verifyStory(args);

    case "reject_story":
      return await rejectStory(args);

    // Bulk Tools
    case "bulk_mark_complete":
      return await bulkMarkComplete(args);

    case "verify_all_in_epic":
      return await verifyAllInEpic(args);

    // Token Efficiency Tools
    case "report_token_usage":
      return await reportTokenUsage(args);

    case "get_cost_summary":
      return await getCostSummary(args);

    case "get_story_token_usage":
      return await getStoryTokenUsage(args);

    case "get_cost_anomalies":
      return await getCostAnomalies(args);

    case "set_token_budget":
      return await setTokenBudget(args);

    // Knowledge Wiki Tools
    case "knowledge_index":
      return await knowledgeIndex(args);

    case "knowledge_search":
      return await knowledgeSearch(args);

    case "knowledge_get":
      return await knowledgeGet(args);

    case "knowledge_context":
      return await knowledgeContext(args);

    case "knowledge_create":
      return await knowledgeCreate(args);

    // Knowledge Management Tools
    case "knowledge_publish":
      return await knowledgePublish(args);

    case "knowledge_drafts":
      return await knowledgeDrafts(args);

    case "knowledge_lint":
      return await knowledgeLint(args);

    case "knowledge_export":
      return await knowledgeExport(args);

    // Discovery Tools
    case "list_routes":
      return await listRoutes();

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const transport = new StdioServerTransport();
await server.connect(transport).catch((err) => {
  process.stderr.write(`loopctl MCP server failed to start: ${err.message}\n`);
  process.exit(1);
});
