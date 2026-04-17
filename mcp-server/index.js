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
// HTTP helper — witness protocol state
// ---------------------------------------------------------------------------

// The witness protocol requires clients to echo back the last-known Signed
// Tree Head (STH) on every authenticated request. On the very first request
// we send X-Loopctl-STH-Bootstrap: true to receive the current STH without
// needing one already. After that we cache and send X-Loopctl-Last-Known-STH.
let lastKnownSTH = null;

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

  const headers = {
    Authorization: `Bearer ${key}`,
    "Content-Type": "application/json",
    Accept: "application/json",
  };

  // Witness protocol: send cached STH or request bootstrap
  if (lastKnownSTH) {
    headers["X-Loopctl-Last-Known-STH"] = lastKnownSTH;
  } else {
    headers["X-Loopctl-STH-Bootstrap"] = "true";
  }

  const options = {
    method,
    headers,
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

  // Witness protocol: cache the STH from response for subsequent requests
  const sthHeader = response.headers.get("x-loopctl-current-sth");
  if (sthHeader) {
    lastKnownSTH = sthHeader;
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

async function createProject({ name, slug, repo_url, description, tech_stack, mission }) {
  const body = { name, slug };
  if (repo_url) body.repo_url = repo_url;
  if (description) body.description = description;
  if (tech_stack) body.tech_stack = tech_stack;
  if (mission) body.mission = mission;
  const result = await apiCall("POST", "/api/v1/projects", body, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function deleteProject({ project_id }) {
  const result = await apiCall(
    "DELETE",
    `/api/v1/projects/${project_id}`,
    null,
    process.env.LOOPCTL_USER_KEY
  );
  return toContent(result);
}

async function getProgress({ project_id, include_cost }) {
  const params = new URLSearchParams();
  if (include_cost) params.set("include_cost", "true");
  const query = params.toString() ? `?${params}` : "";
  const result = await apiCall("GET", `/api/v1/projects/${project_id}/progress${query}`);
  return toContent(result);
}

async function backfillStory({ story_id, reason, evidence_url, pr_number }) {
  if (!story_id) {
    return toContent({
      error: true,
      status: 0,
      body: "`story_id` is required.",
    });
  }
  if (!reason || typeof reason !== "string" || reason.trim() === "") {
    return toContent({
      error: true,
      status: 0,
      body:
        "`reason` is required. Describe why this story is being marked verified without going through the normal lifecycle (e.g. 'completed before loopctl onboarding, see PR #232').",
    });
  }

  const body = { reason };
  if (evidence_url) body.evidence_url = evidence_url;
  if (pr_number != null) body.pr_number = pr_number;

  const result = await apiCall(
    "POST",
    `/api/v1/stories/${story_id}/backfill`,
    body,
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

async function createStory({ project_id, epic_number, epic_id, story }) {
  if (!story || typeof story !== "object") {
    return toContent({
      error: true,
      status: 0,
      body: "`story` is required and must be an object with at least `number` and `title`.",
    });
  }

  // Prefer epic_id path if provided, fall back to project_id + epic_number.
  if (epic_id) {
    const result = await apiCall(
      "POST",
      `/api/v1/epics/${epic_id}/stories`,
      story,
      process.env.LOOPCTL_ORCH_KEY
    );
    return toContent(result);
  }

  if (!project_id || epic_number == null) {
    return toContent({
      error: true,
      status: 0,
      body:
        "Must provide either `epic_id` OR (`project_id` + `epic_number`). " +
        "Use epic_number when you know the epic's human-readable number (e.g. 72) but not its UUID.",
    });
  }

  const body = { epic_number, ...story };
  const result = await apiCall(
    "POST",
    `/api/v1/projects/${project_id}/stories`,
    body,
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

async function importStories({ project_id, payload, payload_path, merge }) {
  const effectivePayload = await resolvePayload(payload, payload_path);
  if (effectivePayload && effectivePayload.error) {
    return toContent(effectivePayload);
  }
  const query = merge ? "?merge=true" : "";
  const result = await apiCall(
    "POST",
    `/api/v1/projects/${project_id}/import${query}`,
    effectivePayload,
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

// Reads JSON payload from either an inline object or an absolute file path.
// Returns the object on success, or an { error, body } shape on failure.
async function resolvePayload(inline, path) {
  if (inline && typeof inline === "object") return inline;
  if (!path) {
    return {
      error: true,
      status: 0,
      body: "Must provide either `payload` (object) or `payload_path` (absolute JSON file path).",
    };
  }
  const fs = await import("node:fs/promises");
  try {
    const raw = await fs.readFile(path, "utf8");
    return JSON.parse(raw);
  } catch (err) {
    return {
      error: true,
      status: 0,
      body: `Could not read payload_path '${path}': ${err.message}`,
    };
  }
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

async function knowledgeIndex({ project_id, story_id }) {
  const basePath = project_id
    ? `/api/v1/projects/${project_id}/knowledge/index`
    : "/api/v1/knowledge/index";
  const params = new URLSearchParams();
  if (story_id) params.set("story_id", story_id);
  const qs = params.toString();
  const path = qs ? `${basePath}?${qs}` : basePath;
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeSearch({ q, project_id, story_id, category, tags, mode, limit }) {
  const params = new URLSearchParams({ q });
  if (project_id) params.set("project_id", project_id);
  if (story_id) params.set("story_id", story_id);
  if (category) params.set("category", category);
  if (tags) params.set("tags", tags);
  if (mode) params.set("mode", mode);
  if (limit != null) params.set("limit", String(limit));

  const result = await apiCall("GET", `/api/v1/knowledge/search?${params}`, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeGet({ article_id, project_id, story_id }) {
  const params = new URLSearchParams();
  if (project_id) params.set("project_id", project_id);
  if (story_id) params.set("story_id", story_id);
  const qs = params.toString();
  const path = qs ? `/api/v1/articles/${article_id}?${qs}` : `/api/v1/articles/${article_id}`;
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeContext({ query, project_id, story_id, limit, recency_weight }) {
  const params = new URLSearchParams({ query });
  if (project_id) params.set("project_id", project_id);
  if (story_id) params.set("story_id", story_id);
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

async function knowledgeBulkPublish({ article_ids }) {
  const result = await apiCall(
    "POST",
    "/api/v1/knowledge/bulk-publish",
    { article_ids },
    process.env.LOOPCTL_USER_KEY
  );
  return toContent(result);
}

async function knowledgeDrafts({ limit, offset, project_id }) {
  const params = new URLSearchParams();
  params.set(
    "limit",
    String(Math.min(limit ?? MAX_PAGE_SIZE, MAX_PAGE_SIZE))
  );
  if (offset != null) params.set("offset", String(offset));
  if (project_id) params.set("project_id", project_id);
  const path = `/api/v1/knowledge/drafts?${params.toString()}`;
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function knowledgeLint({ project_id, stale_days, min_coverage, max_per_category }) {
  const params = new URLSearchParams();
  if (stale_days != null) params.set("stale_days", String(stale_days));
  if (min_coverage != null) params.set("min_coverage", String(min_coverage));
  if (max_per_category != null) params.set("max_per_category", String(max_per_category));
  const qs = params.toString();
  const basePath = project_id
    ? `/api/v1/projects/${project_id}/knowledge/lint`
    : "/api/v1/knowledge/lint";
  const path = qs ? `${basePath}?${qs}` : basePath;
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function knowledgeIngest({ url, content, source_type, project_id }) {
  const body = { source_type };
  if (url) body.url = url;
  if (content) body.content = content;
  if (project_id) body.project_id = project_id;
  const result = await apiCall("POST", "/api/v1/knowledge/ingest", body, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function knowledgeIngestBatch({ items, project_id }) {
  // If a batch-level project_id is supplied, apply it as a default to every
  // item that doesn't already set its own.
  const resolvedItems = Array.isArray(items)
    ? items.map((item) =>
        project_id && item && item.project_id == null
          ? { ...item, project_id }
          : item
      )
    : items;

  const result = await apiCall(
    "POST",
    "/api/v1/knowledge/ingest/batch",
    { items: resolvedItems },
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

async function knowledgeIngestionJobs() {
  const result = await apiCall("GET", "/api/v1/knowledge/ingestion-jobs", null, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

// --- Knowledge Analytics Tools (orch key) ---

async function knowledgeAnalyticsTop({ limit, since_days, access_type } = {}) {
  const params = new URLSearchParams();
  if (limit != null) params.set("limit", String(limit));
  if (since_days != null) params.set("since_days", String(since_days));
  if (access_type) params.set("access_type", access_type);
  const qs = params.toString();
  const path = qs
    ? `/api/v1/knowledge/analytics/top-articles?${qs}`
    : "/api/v1/knowledge/analytics/top-articles";
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function knowledgeArticleStats({ article_id }) {
  const result = await apiCall(
    "GET",
    `/api/v1/knowledge/articles/${article_id}/stats`,
    null,
    process.env.LOOPCTL_ORCH_KEY
  );
  return toContent(result);
}

// Canonical 8-4-4-4-12 UUID shape. Used to reject path-injection attempts
// in tools that interpolate user-supplied IDs into URL path segments.
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

async function knowledgeAgentUsage({ api_key_id, agent_id, limit, since_days } = {}) {
  // Normalize: treat empty strings / whitespace-only strings as missing so the
  // validation below catches them. Otherwise an empty string would slip past
  // the `!= null` checks and produce a malformed URL like /agents/.
  const normalizedApiKeyId =
    typeof api_key_id === "string" && api_key_id.trim() === "" ? null : api_key_id;
  const normalizedAgentId =
    typeof agent_id === "string" && agent_id.trim() === "" ? null : agent_id;

  // Validate: exactly one of api_key_id or agent_id must be provided.
  if (normalizedApiKeyId != null && normalizedAgentId != null) {
    return {
      content: [{ type: "text", text: "Error: pass exactly one of api_key_id or agent_id, not both. Use api_key_id for the api_keys.id credential; use agent_id for the agents.id logical identity." }],
      isError: true,
    };
  }
  if (normalizedApiKeyId == null && normalizedAgentId == null) {
    return {
      content: [{ type: "text", text: "Error: pass exactly one of api_key_id or agent_id. Use api_key_id for the api_keys.id credential; use agent_id for the agents.id logical identity." }],
      isError: true,
    };
  }

  const resolvedId = normalizedApiKeyId ?? normalizedAgentId;

  // Defense-in-depth: the MCP SDK declares `format: "uuid"` on these schemas
  // but does not enforce it for tool arguments. Because `resolvedId` is
  // interpolated directly into a URL path segment, a value containing `/`
  // or `..` would let `fetch()` normalize the request to a different
  // endpoint. Reject anything that isn't a canonical UUID before we touch
  // the network.
  if (typeof resolvedId !== "string" || !UUID_RE.test(resolvedId)) {
    const which = normalizedApiKeyId != null ? "api_key_id" : "agent_id";
    return {
      content: [{ type: "text", text: `Error: ${which} must be a canonical UUID (8-4-4-4-12 hex).` }],
      isError: true,
    };
  }
  const params = new URLSearchParams();
  if (limit != null) params.set("limit", String(limit));
  if (since_days != null) params.set("since_days", String(since_days));
  const qs = params.toString();
  const path = qs
    ? `/api/v1/knowledge/analytics/agents/${resolvedId}?${qs}`
    : `/api/v1/knowledge/analytics/agents/${resolvedId}`;
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_ORCH_KEY);

  // When agent_id alone is passed (new semantic: logical agents.id), emit a
  // one-release-cycle nudge so callers can be explicit about their intent.
  if (normalizedAgentId != null && normalizedApiKeyId == null) {
    const base = toContent(result);
    return {
      ...base,
      _meta: {
        deprecation_hint:
          "knowledge_agent_usage: if you meant the api_keys.id credential, pass it as api_key_id explicitly. The agent_id parameter now refers to the logical agents.id only.",
      },
    };
  }

  return toContent(result);
}

async function knowledgeUnusedArticles({ days_unused, limit } = {}) {
  const params = new URLSearchParams();
  if (days_unused != null) params.set("days_unused", String(days_unused));
  if (limit != null) params.set("limit", String(limit));
  const qs = params.toString();
  const path = qs
    ? `/api/v1/knowledge/analytics/unused-articles?${qs}`
    : "/api/v1/knowledge/analytics/unused-articles";
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

// US-26.2.3: Dispatch lineage tool
async function createDispatch({
  parent_dispatch_id,
  role,
  story_id,
  agent_id,
  expires_in_seconds = 3600,
}) {
  const body = { role, agent_id, expires_in_seconds };
  if (parent_dispatch_id) body.parent_dispatch_id = parent_dispatch_id;
  if (story_id) body.story_id = story_id;

  const result = await apiCall("POST", "/api/v1/dispatches", body);
  return toContent(result);
}

// US-26: Signed Tree Head retrieval
async function getSth({ tenant_id }) {
  const result = await apiCall("GET", `/api/v1/audit/sth/${tenant_id}`);
  return toContent(result);
}

// US-26: System article retrieval
async function getSystemArticles({ slug, category } = {}) {
  const params = new URLSearchParams();
  if (slug) params.set("slug", slug);
  if (category) params.set("category", category);
  const qs = params.toString();
  const result = await apiCall("GET", `/api/v1/articles/system${qs ? "?" + qs : ""}`);
  return toContent(result);
}

// US-26: Cap recovery after session crash
async function recoverCap({ story_id, cap_type, lineage }) {
  const body = { cap_type: cap_type || "start_cap", lineage: lineage || [] };
  const result = await apiCall("POST", `/api/v1/stories/${story_id}/recover-cap`, body);
  return toContent(result);
}

// US-26: Acceptance criteria for a story
async function getAcceptanceCriteria({ story_id }) {
  const result = await apiCall("GET", `/api/v1/stories/${story_id}/acceptance_criteria`);
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
        mission: {
          type: "string",
          description:
            "Optional project mission/goal statement that cascades into story context. Surfaces in get_story responses as project_mission so agents see the why without a second fetch. Max 2000 chars.",
        },
      },
      required: ["name", "slug"],
    },
  },
  {
    name: "delete_project",
    description:
      "Delete a project and all of its dependent resources (epics, stories, audit entries scoped to it). REQUIRES LOOPCTL_USER_KEY to be set in the MCP server env (user role — orchestrator role is NOT sufficient for this destructive operation). The deletion is irreversible.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "The UUID of the project to delete.",
        },
      },
      required: ["project_id"],
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
    name: "backfill_story",
    description:
      "Mark a story as verified when the work was completed outside loopctl (e.g. before the project was onboarded, or during manual ops). " +
      "Bypasses the usual contract/claim/report/review/verify lifecycle because there is no agent lineage to enforce chain-of-custody against. " +
      "Records a provenance marker in `metadata.backfill` plus an audit event so the trust chain stays legible. " +
      "REQUIRES `reason`. Strongly recommend passing `evidence_url` or `pr_number` so future auditors can see what was done.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story to backfill.",
        },
        reason: {
          type: "string",
          description:
            "Why this story is being marked verified without the normal flow (e.g. 'completed before loopctl onboarding, see PR #232').",
        },
        evidence_url: {
          type: "string",
          description: "URL to the evidence (PR, commit, deploy log, etc.).",
        },
        pr_number: {
          type: "integer",
          description: "GitHub/GitLab PR number that delivered the work.",
        },
      },
      required: ["story_id", "reason"],
    },
  },
  {
    name: "create_story",
    description:
      "Create a single story inside an existing epic. " +
      "Use this for one-off additions instead of wrapping the story in a bulk import payload. " +
      "Pass either `epic_id` (UUID) or (`project_id` + `epic_number`) -- the latter is friendlier for agents who know the epic number but not its UUID.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "The UUID of the project (required if using epic_number).",
        },
        epic_number: {
          type: "integer",
          description:
            "The human-readable epic number (e.g. 72). Used together with project_id to locate the epic.",
        },
        epic_id: {
          type: "string",
          description: "The epic UUID. Alternative to project_id+epic_number.",
        },
        story: {
          type: "object",
          description:
            "The full story payload: { number, title, description?, acceptance_criteria?, estimated_hours?, metadata? }. `number` is a string like '72.3'; `title` is required.",
        },
      },
      required: ["story"],
    },
  },
  {
    name: "import_stories",
    description:
      "Import stories into a project from a structured payload (Epic 12 import format). " +
      "Pass `merge: true` to add stories to epics that already exist (otherwise duplicates return 409). " +
      "For large payloads, use `payload_path` to read JSON from disk instead of passing it inline.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "The UUID of the project to import into.",
        },
        payload: {
          type: "object",
          description:
            "The import payload object (epics + stories structure). Either this or `payload_path` is required.",
        },
        payload_path: {
          type: "string",
          description:
            "Absolute path to a JSON file with the import payload. Avoids inline size limits for large epics. Either this or `payload` is required.",
        },
        merge: {
          type: "boolean",
          description:
            "When true, existing epics/stories are updated and new ones added. " +
            "When false or omitted, duplicates return 409.",
          default: false,
        },
      },
      required: ["project_id"],
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
      "Load the knowledge wiki catalog at session start. Returns article metadata grouped by category. " +
      "Pass story_id when working on a loopctl story so reads attribute correctly.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          format: "uuid",
          description: "Optional: scope the index to a specific project UUID.",
        },
        story_id: {
          type: "string",
          format: "uuid",
          description: "Optional: loopctl story UUID for attribution tracking.",
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_search",
    description:
      "Search the knowledge wiki by topic. Returns snippets. " +
      "Pass story_id when working on a loopctl story so reads attribute correctly.",
    inputSchema: {
      type: "object",
      properties: {
        q: {
          type: "string",
          description: "Search query string.",
        },
        project_id: {
          type: "string",
          format: "uuid",
          description: "Optional: scope search to a specific project UUID.",
        },
        story_id: {
          type: "string",
          format: "uuid",
          description: "Optional: loopctl story UUID for attribution tracking.",
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
      "Get full article content by ID. Use after search to read an article in detail. " +
      "Pass story_id when working on a loopctl story so reads attribute correctly.",
    inputSchema: {
      type: "object",
      properties: {
        article_id: {
          type: "string",
          format: "uuid",
          description: "The UUID of the article.",
        },
        project_id: {
          type: "string",
          format: "uuid",
          description: "Optional: project UUID for attribution tracking.",
        },
        story_id: {
          type: "string",
          format: "uuid",
          description: "Optional: loopctl story UUID for attribution tracking.",
        },
      },
      required: ["article_id"],
    },
  },
  {
    name: "knowledge_context",
    description:
      "Get ranked full articles for a task query. Returns best knowledge with linked references. " +
      "Pass story_id when working on a loopctl story so reads attribute correctly.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "The task or topic query to find relevant knowledge for.",
        },
        project_id: {
          type: "string",
          format: "uuid",
          description: "Optional: scope context to a specific project UUID.",
        },
        story_id: {
          type: "string",
          format: "uuid",
          description: "Optional: loopctl story UUID for attribution tracking.",
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
    name: "knowledge_bulk_publish",
    description:
      "Atomically publish up to 100 draft articles in a single call. " +
      "REQUIRES LOOPCTL_USER_KEY to be set in the MCP server env (user role — " +
      "orchestrator role is NOT sufficient for this destructive operation). " +
      "All articles must be drafts belonging to the tenant; if any fail validation, " +
      "the entire operation rolls back.",
    inputSchema: {
      type: "object",
      properties: {
        article_ids: {
          type: "array",
          items: { type: "string" },
          description: "List of draft article UUIDs to publish (max 100).",
          maxItems: 100,
        },
      },
      required: ["article_ids"],
    },
  },
  {
    name: "knowledge_drafts",
    description:
      "List draft (unpublished) knowledge articles. Requires orchestrator role. " +
      "Returns paginated drafts with total_count in meta. Max 20 per page.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "integer",
          description: "Max drafts per page. Default 20, hard max 20.",
          default: 20,
          minimum: 1,
          maximum: 20,
        },
        offset: {
          type: "integer",
          description: "Pagination offset. Default 0.",
          default: 0,
          minimum: 0,
        },
        project_id: {
          type: "string",
          description: "Optional: filter drafts to a specific project UUID.",
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_lint",
    description:
      "Run a lint check on the knowledge wiki to identify stale, low-coverage, or broken articles. " +
      "Requires orchestrator role. Optionally scoped to a project. " +
      "Each issue category is capped at max_per_category (default 50) with true totals " +
      "exposed in summary.total_per_category and per-category truncated flags.",
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
          type: "integer",
          description:
            "Optional: minimum published articles per category below which a coverage gap is reported (default 3).",
          minimum: 1,
        },
        max_per_category: {
          type: "integer",
          description:
            "Max items per category to return. Default 50, max 500. True totals are still reported in summary.total_per_category.",
          default: 50,
          minimum: 1,
          maximum: 500,
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

  // Knowledge Ingestion Tools
  {
    name: "knowledge_ingest",
    description:
      "Submit a URL or raw content for knowledge extraction. " +
      "Enqueues an Oban job that fetches the content (if URL), extracts knowledge articles via LLM, " +
      "and inserts them as draft articles. Requires orchestrator role.",
    inputSchema: {
      type: "object",
      properties: {
        url: {
          type: "string",
          description: "URL to fetch content from (exactly one of url or content required).",
        },
        content: {
          type: "string",
          description: "Raw content to extract knowledge from (exactly one of url or content required).",
        },
        source_type: {
          type: "string",
          description: "Source type (e.g., newsletter, skill, web_article, ingestion). Required.",
        },
        project_id: {
          type: "string",
          description: "Optional: scope extracted articles to a specific project UUID.",
        },
      },
      required: ["source_type"],
    },
  },
  {
    name: "knowledge_ingest_batch",
    description:
      "Submit up to 50 ingestion items in a single request. Each item follows the same " +
      "shape as knowledge_ingest (url OR content, source_type required). Returns a " +
      "per-item result array — individual failures do not abort the batch. " +
      "Requires orchestrator role.",
    inputSchema: {
      type: "object",
      properties: {
        items: {
          type: "array",
          description: "Array of ingestion items (1-50). Each item must include source_type and exactly one of url or content.",
          minItems: 1,
          maxItems: 50,
          items: {
            type: "object",
            properties: {
              url: {
                type: "string",
                description: "URL to fetch content from (exactly one of url or content required).",
              },
              content: {
                type: "string",
                description: "Raw content to extract from (exactly one of url or content required).",
              },
              source_type: {
                type: "string",
                description: "Source type (e.g., newsletter, skill, web_article, ingestion). Required.",
              },
              project_id: {
                type: "string",
                description: "Optional: scope the item to a specific project UUID.",
              },
              metadata: {
                type: "object",
                description: "Optional metadata map.",
              },
            },
            required: ["source_type"],
          },
        },
        project_id: {
          type: "string",
          description: "Optional batch-level default project UUID applied to items that don't specify their own.",
        },
      },
      required: ["items"],
    },
  },
  {
    name: "knowledge_ingestion_jobs",
    description:
      "List recent content ingestion jobs for the current tenant. " +
      "Returns jobs from the last 7 days, max 50 results. Requires orchestrator role.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },

  // Knowledge Analytics Tools (orchestrator key)
  {
    name: "knowledge_analytics_top",
    description:
      "Return the top accessed knowledge articles for the tenant. " +
      "Use to identify which articles agents actually read. Requires orchestrator role.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "integer",
          description: "Max rows to return. Default 20, max 100.",
          minimum: 1,
          maximum: 100,
        },
        since_days: {
          type: "integer",
          description: "Look back this many days. Default 7.",
          minimum: 1,
          maximum: 365,
        },
        access_type: {
          type: "string",
          enum: ["search", "get", "context", "index"],
          description: "Optional: restrict to a single access type.",
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_article_stats",
    description:
      "Return per-article usage statistics: total accesses, unique agents, " +
      "by-type breakdown, and the 10 most recent events. Requires orchestrator role.",
    inputSchema: {
      type: "object",
      properties: {
        article_id: {
          type: "string",
          description: "The UUID of the article to inspect.",
        },
      },
      required: ["article_id"],
    },
  },
  {
    name: "knowledge_agent_usage",
    description:
      "Return knowledge usage for an agent: total reads, unique articles, top read articles. " +
      "Pass api_key_id (api_keys.id credential) OR agent_id (agents.id logical identity) — not both. " +
      "Requires orchestrator role.",
    inputSchema: {
      type: "object",
      properties: {
        api_key_id: {
          type: "string",
          format: "uuid",
          description: "The api_keys.id credential UUID. Use this when you have the raw API key ID.",
        },
        agent_id: {
          type: "string",
          format: "uuid",
          description: "The agents.id logical identity UUID. Use this when you have the agent registry ID.",
        },
        limit: {
          type: "integer",
          description: "Max top articles to return. Default 20, max 100.",
          minimum: 1,
          maximum: 100,
        },
        since_days: {
          type: "integer",
          description: "Look back this many days. Default 7.",
          minimum: 1,
          maximum: 365,
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_unused_articles",
    description:
      "Return published articles that have not been accessed in the configured " +
      "time window. Use to identify dead-weight knowledge. Requires orchestrator role.",
    inputSchema: {
      type: "object",
      properties: {
        days_unused: {
          type: "integer",
          description: "Window length in days. Default 30.",
          minimum: 1,
          maximum: 365,
        },
        limit: {
          type: "integer",
          description: "Max rows to return. Default 50, max 200.",
          minimum: 1,
          maximum: 200,
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

  // Dispatch Tool (US-26.2.3)
  {
    name: "dispatch",
    description:
      "Mint an ephemeral api_key for a sub-agent dispatch. " +
      "The raw_key is returned ONCE — pass it to the sub-agent via its launch arguments, " +
      "never store it in env vars. The key expires after expires_in_seconds.",
    inputSchema: {
      type: "object",
      properties: {
        parent_dispatch_id: {
          type: "string",
          description: "UUID of the parent dispatch (omit for root dispatch).",
        },
        role: {
          type: "string",
          enum: ["agent", "orchestrator"],
          description: "Role for the sub-agent.",
        },
        story_id: {
          type: "string",
          description: "Optional: UUID of the story this dispatch is for.",
        },
        agent_id: {
          type: "string",
          description: "UUID of the agent being dispatched.",
        },
        expires_in_seconds: {
          type: "integer",
          description: "Key lifetime in seconds (default 3600, max 14400).",
          default: 3600,
        },
      },
      required: ["role", "agent_id"],
    },
  },

  // Chain of Custody v2 tools
  {
    name: "get_sth",
    description: "Get the latest Signed Tree Head for a tenant's audit chain. Public — no auth required.",
    inputSchema: {
      type: "object",
      properties: {
        tenant_id: { type: "string", description: "Tenant UUID." },
      },
      required: ["tenant_id"],
    },
  },
  {
    name: "get_system_articles",
    description: "List or retrieve system-scoped wiki articles. Public — no auth required.",
    inputSchema: {
      type: "object",
      properties: {
        slug: { type: "string", description: "Optional: fetch a single article by slug." },
        category: { type: "string", description: "Optional: filter by category (pattern, convention, decision, finding, reference)." },
      },
    },
  },
  {
    name: "recover_cap",
    description: "Re-mint a capability token for a story you're assigned to. Use after a session crash when you've lost your cap.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: { type: "string", description: "Story UUID." },
        cap_type: { type: "string", enum: ["start_cap", "report_cap"], description: "Which cap to recover (default: start_cap)." },
        lineage: { type: "array", items: { type: "string" }, description: "Your dispatch lineage path." },
      },
      required: ["story_id"],
    },
  },
  {
    name: "get_acceptance_criteria",
    description: "List acceptance criteria for a story with their verification status.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: { type: "string", description: "Story UUID." },
      },
      required: ["story_id"],
    },
  },
];

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------

const server = new Server(
  {
    name: "loopctl",
    version: "1.2.0",
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

    case "delete_project":
      return await deleteProject(args);

    case "get_progress":
      return await getProgress(args);

    case "backfill_story":
      return await backfillStory(args);

    case "create_story":
      return await createStory(args);

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

    case "knowledge_bulk_publish":
      return await knowledgeBulkPublish(args);

    case "knowledge_drafts":
      return await knowledgeDrafts(args);

    case "knowledge_lint":
      return await knowledgeLint(args);

    case "knowledge_export":
      return await knowledgeExport(args);

    // Knowledge Ingestion Tools
    case "knowledge_ingest":
      return await knowledgeIngest(args);

    case "knowledge_ingest_batch":
      return await knowledgeIngestBatch(args);

    case "knowledge_ingestion_jobs":
      return await knowledgeIngestionJobs();

    // Knowledge Analytics Tools
    case "knowledge_analytics_top":
      return await knowledgeAnalyticsTop(args);

    case "knowledge_article_stats":
      return await knowledgeArticleStats(args);

    case "knowledge_agent_usage":
      return await knowledgeAgentUsage(args);

    case "knowledge_unused_articles":
      return await knowledgeUnusedArticles(args);

    // Discovery Tools
    case "list_routes":
      return await listRoutes();

    case "dispatch":
      return await createDispatch(args);

    case "get_sth":
      return await getSth(args);

    case "get_system_articles":
      return await getSystemArticles(args);

    case "recover_cap":
      return await recoverCap(args);

    case "get_acceptance_criteria":
      return await getAcceptanceCriteria(args);

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
