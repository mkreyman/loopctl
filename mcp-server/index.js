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
//
// Security: `payload_path` is read with the MCP process's filesystem
// privileges. Because agents can set this argument via prompt injection,
// we validate aggressively:
//   * require absolute path
//   * reject /proc, /dev, /sys (pseudo-filesystems that could DoS or leak)
//   * stat first and cap at 5 MiB (server also enforces a body size limit)
async function resolvePayload(inline, payloadPath) {
  if (inline && typeof inline === "object") return inline;
  if (!payloadPath) {
    return {
      error: true,
      status: 0,
      body: "Must provide either `payload` (object) or `payload_path` (absolute JSON file path).",
    };
  }

  const nodePath = await import("node:path");
  if (!nodePath.isAbsolute(payloadPath)) {
    return {
      error: true,
      status: 0,
      body: `payload_path must be absolute (got '${payloadPath}').`,
    };
  }

  const blockedPrefixes = ["/proc/", "/dev/", "/sys/", "/proc", "/dev", "/sys"];
  if (blockedPrefixes.some((p) => payloadPath === p.replace(/\/$/, "") || payloadPath.startsWith(p))) {
    return {
      error: true,
      status: 0,
      body: `payload_path refused: '${payloadPath}' targets a pseudo-filesystem path.`,
    };
  }

  const MAX_PAYLOAD_BYTES = 5 * 1024 * 1024;
  const fs = await import("node:fs/promises");

  try {
    const stat = await fs.stat(payloadPath);
    if (!stat.isFile()) {
      return {
        error: true,
        status: 0,
        body: `payload_path '${payloadPath}' is not a regular file.`,
      };
    }
    if (stat.size > MAX_PAYLOAD_BYTES) {
      return {
        error: true,
        status: 0,
        body: `payload_path '${payloadPath}' is ${stat.size} bytes, exceeds max ${MAX_PAYLOAD_BYTES}.`,
      };
    }
    const raw = await fs.readFile(payloadPath, "utf8");
    return JSON.parse(raw);
  } catch (err) {
    return {
      error: true,
      status: 0,
      body: `Could not read payload_path '${payloadPath}': ${err.message}`,
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

async function knowledgeIndex({ project_id, story_id, category, tags, match, offset, limit, fields }) {
  if (project_id && !UUID_RE.test(project_id)) {
    return {
      content: [{ type: "text", text: "Error: project_id must be a canonical UUID (8-4-4-4-12 hex)." }],
      isError: true,
    };
  }
  const basePath = project_id
    ? `/api/v1/projects/${project_id}/knowledge/index`
    : "/api/v1/knowledge/index";
  const params = new URLSearchParams();
  if (story_id) params.set("story_id", story_id);
  if (category) params.set("category", category);
  if (tags) params.set("tags", tags);
  if (match) params.set("match", match);
  if (offset != null) params.set("offset", String(offset));
  if (limit != null) params.set("limit", String(limit));
  if (fields) params.set("fields", Array.isArray(fields) ? fields.join(",") : fields);
  const qs = params.toString();
  const path = qs ? `${basePath}?${qs}` : basePath;
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeStats({ project_id }) {
  if (project_id && !UUID_RE.test(project_id)) {
    return {
      content: [{ type: "text", text: "Error: project_id must be a canonical UUID (8-4-4-4-12 hex)." }],
      isError: true,
    };
  }
  const path = project_id
    ? `/api/v1/projects/${project_id}/knowledge/stats`
    : "/api/v1/knowledge/stats";
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeCount({
  project_id,
  category,
  status,
  tags,
  match,
  source_type,
  source_id,
  idempotency_key,
}) {
  const params = new URLSearchParams();
  if (project_id) params.set("project_id", project_id);
  if (category) params.set("category", category);
  if (status) params.set("status", status);
  if (tags) params.set("tags", tags);
  if (match) params.set("match", match);
  if (source_type) params.set("source_type", source_type);
  if (source_id) params.set("source_id", source_id);
  if (idempotency_key) params.set("idempotency_key", idempotency_key);
  const qs = params.toString();
  const path = qs ? `/api/v1/knowledge/count?${qs}` : "/api/v1/knowledge/count";
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeFacets({
  project_id,
  category,
  status,
  tags,
  match,
  tag_prefix,
  limit,
}) {
  const params = new URLSearchParams();
  params.set("group_by", "tag");
  if (project_id) params.set("project_id", project_id);
  if (category) params.set("category", category);
  if (status) params.set("status", status);
  if (tags) params.set("tags", tags);
  if (match) params.set("match", match);
  if (tag_prefix) params.set("tag_prefix", tag_prefix);
  if (limit != null) params.set("limit", String(limit));
  const result = await apiCall(
    "GET",
    `/api/v1/knowledge/facets?${params}`,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

async function knowledgeSearch({ q, project_id, story_id, category, tags, match, mode, limit, offset }) {
  const params = new URLSearchParams();
  if (q != null && q !== "") params.set("q", q);
  if (project_id) params.set("project_id", project_id);
  if (story_id) params.set("story_id", story_id);
  if (category) params.set("category", category);
  if (tags) params.set("tags", tags);
  if (match) params.set("match", match);
  if (mode) params.set("mode", mode);
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));

  const result = await apiCall("GET", `/api/v1/knowledge/search?${params}`, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeList({
  project_id,
  category,
  status,
  tags,
  match,
  source_type,
  source_id,
  idempotency_key,
  limit,
  offset,
  include_body,
}) {
  const params = new URLSearchParams();
  if (project_id) params.set("project_id", project_id);
  if (category) params.set("category", category);
  if (status) params.set("status", status);
  if (tags) params.set("tags", tags);
  if (match) params.set("match", match);
  if (source_type) params.set("source_type", source_type);
  if (source_id) params.set("source_id", source_id);
  if (idempotency_key) params.set("idempotency_key", idempotency_key);
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  // Body-less summary by default (safe to enumerate large pages); opt into full
  // bodies (byte-budget bounded server-side) with include_body: true.
  if (include_body === true) params.set("include_body", "true");

  const result = await apiCall(
    "GET",
    `/api/v1/articles?${params}`,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
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

async function knowledgeCreate({
  title,
  body,
  category,
  tags,
  project_id,
  draft,
  source_type,
  source_id,
  idempotency_key,
}) {
  const payload = { title, body };
  if (category) payload.category = category;
  if (tags) payload.tags = tags;
  if (project_id) payload.project_id = project_id;
  if (source_type) payload.source_type = source_type;
  if (source_id) payload.source_id = source_id;
  if (idempotency_key) payload.idempotency_key = idempotency_key;

  // Articles publish on create by default for every role (including agent), so a
  // plain create routes through the agent key and is immediately visible. Pass
  // draft:true to stage it for later review instead — publish it afterwards with
  // knowledge_publish.
  if (draft) payload.draft = true;

  const result = await apiCall(
    "POST",
    "/api/v1/articles",
    payload,
    process.env.LOOPCTL_AGENT_KEY,
  );
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

  // Partial success returns 200 even when nothing published. Surface a warning
  // so the agent doesn't treat not_found/errored ids as success.
  const counts = result?.meta?.counts;
  if (counts && (counts.not_found > 0 || counts.errored > 0)) {
    const warning =
      `WARNING: bulk-publish was partial — published ${counts.published}, ` +
      `skipped ${counts.skipped}, not_found ${counts.not_found}, errored ${counts.errored} ` +
      `(of ${counts.requested} requested). Inspect meta.results for per-id outcomes; ` +
      `not_found/errored ids were NOT published.`;
    return {
      content: [{ type: "text", text: warning }, ...toContent(result).content],
    };
  }

  return toContent(result);
}

async function knowledgeUnpublish({ article_id }) {
  const result = await apiCall(
    "POST",
    `/api/v1/articles/${article_id}/unpublish`,
    null,
    process.env.LOOPCTL_USER_KEY
  );
  return toContent(result);
}

async function knowledgeArchive({ article_id }) {
  const result = await apiCall(
    "POST",
    `/api/v1/articles/${article_id}/archive`,
    null,
    process.env.LOOPCTL_USER_KEY
  );
  return toContent(result);
}

async function knowledgeDelete({ article_id }) {
  const result = await apiCall(
    "DELETE",
    `/api/v1/articles/${article_id}`,
    null,
    process.env.LOOPCTL_USER_KEY
  );
  return toContent(result);
}

async function knowledgeBulkDelete({ article_ids, source_type, source_id, tag, confirm }) {
  const payload = {};
  if (article_ids) payload.article_ids = article_ids;
  if (source_type) payload.source_type = source_type;
  if (source_id) payload.source_id = source_id;
  if (tag) payload.tag = tag;
  if (confirm) payload.confirm = confirm;

  const result = await apiCall(
    "POST",
    "/api/v1/knowledge/bulk-delete",
    payload,
    process.env.LOOPCTL_USER_KEY,
  );

  // Partial success returns 200 even when some/none archived — surface a warning
  // so the agent doesn't treat not_found/errored, or a nothing-archived run, as
  // success.
  const counts = result?.meta?.counts;
  if (
    counts &&
    (counts.not_found > 0 ||
      counts.errored > 0 ||
      (counts.archived === 0 && counts.requested > 0))
  ) {
    const warning =
      `WARNING: bulk-delete was partial — archived ${counts.archived}, ` +
      `skipped ${counts.skipped}, not_found ${counts.not_found}, errored ${counts.errored} ` +
      `(of ${counts.requested}). Inspect meta.results; not_found/errored ids were NOT archived.`;
    return {
      content: [{ type: "text", text: warning }, ...toContent(result).content],
    };
  }

  return toContent(result);
}

async function knowledgeDrafts({ limit, offset, project_id }) {
  const params = new URLSearchParams();
  // Pass `limit` through verbatim (like knowledge_list/index/search) so the
  // server honors it up to its max page size and returns 400 above it — rather
  // than silently clamping client-side, which would truncate draft enumeration.
  if (limit != null) params.set("limit", String(limit));
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

async function knowledgeIngest({ url, content, source_type, project_id, publish }) {
  const body = { source_type };
  if (url) body.url = url;
  if (content) body.content = content;
  if (project_id) body.project_id = project_id;
  if (publish) body.publish = true;
  const result = await apiCall("POST", "/api/v1/knowledge/ingest", body, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function knowledgeIngestBatch({ items, project_id, publish }) {
  // Apply batch-level project_id / publish as defaults to any item that doesn't
  // set its own.
  const resolvedItems = Array.isArray(items)
    ? items.map((item) => {
        if (!item) return item;
        let resolved = item;
        if (project_id && resolved.project_id == null)
          resolved = { ...resolved, project_id };
        if (publish && resolved.publish == null) resolved = { ...resolved, publish: true };
        return resolved;
      })
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

// --- OKF (Open Knowledge Format) interchange ---

// Guard a user-supplied absolute filesystem path against pseudo-filesystems.
function assertSafeAbsolutePath(nodePath, p, label) {
  if (!nodePath.isAbsolute(p)) {
    return `${label} must be an absolute path (got '${p}').`;
  }
  const blocked = ["/proc", "/dev", "/sys"];
  if (blocked.some((b) => p === b || p.startsWith(b + "/"))) {
    return `${label} refused: '${p}' targets a pseudo-filesystem path.`;
  }
  return null;
}

async function knowledgeOkfExport({ project_id, out_dir }) {
  const basePath = project_id
    ? `/api/v1/projects/${project_id}/knowledge/okf/export`
    : "/api/v1/knowledge/okf/export";

  const result = await apiCall(
    "GET",
    `${basePath}?format=json`,
    null,
    process.env.LOOPCTL_USER_KEY,
  );

  if (result.error) return toContent(result);

  const bundle = result.data || result;
  const files = bundle.files || {};
  const meta = bundle.meta || {};

  if (!out_dir) {
    return toContent({ meta, file_count: Object.keys(files).length, files });
  }

  const nodePath = await import("node:path");
  const pathErr = assertSafeAbsolutePath(nodePath, out_dir, "out_dir");
  if (pathErr) {
    return { content: [{ type: "text", text: `Error: ${pathErr}` }], isError: true };
  }
  // Normalize so `..`/trailing-slash can't defeat the per-file fence below.
  const root = nodePath.resolve(out_dir);

  const fs = await import("node:fs/promises");
  let written = 0;
  for (const [rel, content] of Object.entries(files)) {
    // Keep writes inside root even if a server-supplied path is adversarial.
    const dest = nodePath.resolve(root, rel);
    if (dest !== root && !dest.startsWith(root + nodePath.sep)) continue;
    await fs.mkdir(nodePath.dirname(dest), { recursive: true });
    await fs.writeFile(dest, content, "utf8");
    written += 1;
  }

  return toContent({ meta, out_dir: root, written });
}

async function knowledgeOkfImport({ bundle_dir, project_id, merge, dry_run }) {
  const nodePath = await import("node:path");
  const pathErr = assertSafeAbsolutePath(nodePath, bundle_dir, "bundle_dir");
  if (pathErr) {
    return { content: [{ type: "text", text: `Error: ${pathErr}` }], isError: true };
  }

  const fs = await import("node:fs/promises");

  let stat;
  try {
    stat = await fs.stat(bundle_dir);
  } catch {
    return { content: [{ type: "text", text: `Error: bundle_dir '${bundle_dir}' not found.` }], isError: true };
  }
  if (!stat.isDirectory()) {
    return { content: [{ type: "text", text: `Error: bundle_dir '${bundle_dir}' is not a directory.` }], isError: true };
  }

  // Kept in step with the server-side caps in okf_controller.ex.
  const MAX_FILES = 10_000;
  const MAX_TOTAL_BYTES = 50 * 1024 * 1024;
  const files = {};
  let totalBytes = 0;

  async function walk(dir) {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const abs = nodePath.join(dir, entry.name);
      // Never traverse or read through symlinks (escape out of bundle_dir).
      if (entry.isSymbolicLink()) {
        continue;
      } else if (entry.isDirectory()) {
        await walk(abs);
      } else if (entry.isFile() && entry.name.endsWith(".md")) {
        if (Object.keys(files).length >= MAX_FILES) {
          throw new Error(`bundle exceeds ${MAX_FILES} files`);
        }
        const content = await fs.readFile(abs, "utf8");
        totalBytes += Buffer.byteLength(content, "utf8");
        if (totalBytes > MAX_TOTAL_BYTES) {
          throw new Error("bundle exceeds 25 MiB total");
        }
        files[nodePath.relative(bundle_dir, abs).split(nodePath.sep).join("/")] = content;
      }
    }
  }

  try {
    await walk(bundle_dir);
  } catch (e) {
    return { content: [{ type: "text", text: `Error: ${e.message}` }], isError: true };
  }

  if (Object.keys(files).length === 0) {
    return { content: [{ type: "text", text: `Error: no .md files found under '${bundle_dir}'.` }], isError: true };
  }

  const payload = { files };
  if (project_id) payload.project_id = project_id;
  if (merge != null) payload.merge = merge;
  if (dry_run != null) payload.dry_run = dry_run;

  const result = await apiCall(
    "POST",
    "/api/v1/knowledge/okf/import",
    payload,
    process.env.LOOPCTL_USER_KEY,
  );
  return toContent(result);
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
      "Mark a story as verified when the work was completed outside loopctl (e.g. before the project was onboarded). " +
      "REFUSED for stories that have any loopctl dispatch lineage — non-pending agent_status, assigned_agent_id, implementer_dispatch_id, " +
      "or verifier_dispatch_id set. Also refused for stories already `:verified` (idempotent no-op when the same payload is sent) or `:rejected`. " +
      "Records a provenance marker in `metadata.backfill` plus an audit event and a `story.backfilled` webhook. " +
      "REQUIRES `reason`. Strongly recommend passing `evidence_url` (http/https, no credentials in userinfo) and `pr_number`.",
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
            "The import payload object (epics + stories structure). Either this or `payload_path` is required. If BOTH are passed, `payload` wins.",
        },
        payload_path: {
          type: "string",
          description:
            "Absolute path to a JSON file with the import payload. Avoids inline size limits for large epics. Ignored if `payload` is also passed.",
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
      "Browse/paginate the knowledge wiki catalog. Returns LIGHTWEIGHT article metadata grouped by " +
      "category — by default only id, title, category per article (NOT full metadata). " +
      "Honors category/tags filters and offset/limit pagination with deterministic ordering, so " +
      "every article is reachable (meta.categories reports per-category counts over the whole " +
      "filtered set; meta.has_more/meta.truncated signal more pages). Use `fields` to control the " +
      "projection (request tags/status/updated_at explicitly; id and category are always included) " +
      "to keep the payload small on large catalogs. " +
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
        category: {
          type: "string",
          enum: ["pattern", "convention", "decision", "finding", "reference"],
          description: "Optional: filter to a single category. Rejected (400) if unknown.",
        },
        tags: {
          type: "string",
          description: "Optional: comma-separated tags; matches articles carrying ANY of them.",
        },
        match: {
          type: "string",
          enum: ["any", "all"],
          description: "Optional: tag match mode — 'any' (default, OR) or 'all' (AND, every tag).",
        },
        offset: {
          type: "integer",
          description: "Optional: rows to skip for pagination (default 0).",
        },
        limit: {
          type: "integer",
          description: "Optional: max articles per page (default 1000, max 1000).",
        },
        fields: {
          type: "array",
          items: {
            type: "string",
            enum: ["id", "title", "category", "tags", "status", "updated_at"],
          },
          description:
            "Optional: projection of article fields to return. Default: id, title, category. `id` is always included.",
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_list",
    description:
      "List articles (id, title, category, status, tags, source_type, source_id, " +
      "idempotency_key, timestamps), filtered and paginated. **Body-less summary by default** " +
      "— the right tool to enumerate, dedup, or repair at scale (safe to page up to limit=1000). " +
      "Pass `include_body: true` to also return the full `body`, in which case the server bounds " +
      "the page by a ~5 MB serialized-body budget and returns meta.next_offset/has_more/" +
      "byte_truncated for continuation (for a single full body use knowledge_get; for the relevant " +
      "bodies use knowledge_context; for a bulk content dump use knowledge_export). Unlike " +
      "knowledge_search (ranked, PUBLISHED-only, lags writes while embeddings index) and " +
      "knowledge_index (id/title/category only), this is the LAG-FREE, ALL-STATUS read of the DB " +
      "of record (draft, published, archived, superseded visible). Use for idempotency/existence " +
      "checks: filter by `tags`, `source_type`+`source_id`, or `idempotency_key` and read " +
      "`meta.total_count` (exact) to answer \"does an article for X already exist?\" reliably " +
      "right after a write. Paginate via offset/limit.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          format: "uuid",
          description: "Optional: scope to a project UUID.",
        },
        category: {
          type: "string",
          description: "Optional: filter by category.",
        },
        status: {
          type: "string",
          description: "Optional: filter by status (draft, published, archived, superseded).",
        },
        tags: {
          type: "string",
          description: "Optional: comma-separated tags; matches articles carrying ANY of them.",
        },
        match: {
          type: "string",
          enum: ["any", "all"],
          description: "Optional: tag match mode — 'any' (default, OR) or 'all' (AND, every tag).",
        },
        source_type: {
          type: "string",
          description: "Optional: filter by source_type.",
        },
        source_id: {
          type: "string",
          description: "Optional: filter by source_id (a malformed id matches nothing).",
        },
        idempotency_key: {
          type: "string",
          description:
            "Optional: filter by exact idempotency_key — the lag-free existence check for a " +
            "prior capture.",
        },
        offset: {
          type: "integer",
          description: "Optional: rows to skip for pagination (default 0).",
        },
        limit: {
          type: "integer",
          description:
            "Optional: max articles per page (default 20, max 1000). A limit above " +
            "the max is rejected with 400 — not silently clamped — so paging by offset " +
            "over meta.total_count enumerates the complete set without skipping rows.",
        },
        include_body: {
          type: "boolean",
          description:
            "Optional (default false): when true, include the full article `body`. The page is " +
            "then bounded by a ~5 MB serialized-body budget (it may return fewer than `limit` " +
            "rows); continue via meta.next_offset while meta.has_more is true. Leave false to " +
            "enumerate metadata cheaply at scale.",
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_stats",
    description:
      "Get aggregate article counts for the wiki without pulling any article metadata. " +
      "Returns { total, by_category, by_status } via cheap COUNT(*) GROUP BY. This is the " +
      "right tool to answer \"how many articles are in this project?\" — knowledge_index " +
      "pages article metadata and knowledge_search's total_count is query-dependent. Counts " +
      "span all statuses (draft/published/archived/superseded); see by_status for the split. " +
      "Note: `total` is NOT the same as knowledge_index's meta.total_count (which counts only " +
      "published) — they differ whenever drafts/archived exist.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          format: "uuid",
          description:
            "Optional: scope counts to a project (counts both tenant-wide and project-specific articles).",
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_count",
    description:
      "Count articles matching filters WITHOUT returning any rows. Accepts the same filters " +
      "as knowledge_list (category, status, tags, match, source_type, source_id, " +
      "idempotency_key, project_id). With tags + match:'all' it counts articles carrying ALL " +
      "the tags; add status:'published' to answer \"how many PUBLISHED articles tagged both X " +
      "and Y\". Removes the need to paginate rows just to count. Returns { count }.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: { type: "string", format: "uuid", description: "Optional: scope to a project UUID." },
        category: { type: "string", description: "Optional: filter by category." },
        status: { type: "string", description: "Optional: filter by status." },
        tags: { type: "string", description: "Optional: comma-separated tags." },
        match: {
          type: "string",
          enum: ["any", "all"],
          description: "Tag match mode: 'any' (default, OR) or 'all' (AND — carries every tag).",
        },
        source_type: { type: "string", description: "Optional: filter by source_type." },
        source_id: { type: "string", description: "Optional: filter by source_id." },
        idempotency_key: { type: "string", description: "Optional: filter by idempotency_key." },
      },
      required: [],
    },
  },
  {
    name: "knowledge_facets",
    description:
      "Count articles grouped by each distinct tag, over the filtered set, WITHOUT returning " +
      "rows. Returns { data: { tag: count }, meta: { distinct_count } }. Pass tag_prefix to " +
      "restrict to a tag family (e.g. 'book-') so you get the DISTINCT count of that family " +
      "(how many distinct books) plus per-member totals — without dragging tens of thousands " +
      "of rows through context. Honors the same filters as knowledge_count (status, tags, match).",
    inputSchema: {
      type: "object",
      properties: {
        project_id: { type: "string", format: "uuid", description: "Optional: scope to a project UUID." },
        category: { type: "string", description: "Optional: filter by category." },
        status: { type: "string", description: "Optional: filter by status." },
        tags: { type: "string", description: "Optional: comma-separated tags." },
        match: {
          type: "string",
          enum: ["any", "all"],
          description: "Tag match mode: 'any' (default, OR) or 'all' (AND).",
        },
        tag_prefix: {
          type: "string",
          description: "Optional: only tags starting with this literal prefix (e.g. 'book-').",
        },
        limit: { type: "integer", description: "Optional: max facet rows (default all, max 1000)." },
      },
      required: [],
    },
  },
  {
    name: "knowledge_search",
    description:
      "Search the knowledge wiki by topic. Returns snippets. Ranked, and returns PUBLISHED " +
      "articles only; it LAGS writes by minutes while embeddings index. Do NOT use it for " +
      "existence/idempotency/dedup checks ('already captured?') — a freshly-written article will " +
      "false-negative. Use knowledge_list (lag-free, all-status, exact meta.total_count) for that. " +
      "q is optional when tags and/or category are supplied: in that list mode it returns the " +
      "COMPLETE filtered set (no relevance ranking) paginated via offset/limit over " +
      "meta.total_count, so you can enumerate every article carrying a tag/category. " +
      "IMPORTANT: meta.total_count is mode-dependent — read meta.total_count_scope to know what " +
      "it counts: keyword_matches (stop-word-filtered tsquery matches; 'the' matches ~nothing), " +
      "ranked_corpus (semantic ranks all EMBEDDED published articles — that embedded set's size, " +
      "not a match count, and <= the published count), merged_candidates (combined: deduped UNION of " +
      "a keyword and a semantic sub-search, each capped at 100, so up to ~200), or filtered_set " +
      "(list mode: the full set). Do NOT use a relevance-mode total_count to size the wiki — use " +
      "list mode or knowledge_stats. " +
      "Pass story_id when working on a loopctl story so reads attribute correctly.",
    inputSchema: {
      type: "object",
      properties: {
        q: {
          type: "string",
          description:
            "Search query string. Optional when tags/category are supplied (enumeration mode).",
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
        match: {
          type: "string",
          enum: ["any", "all"],
          description: "Optional: tag match mode — 'any' (default, OR) or 'all' (AND, every tag).",
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
        offset: {
          type: "integer",
          description: "Optional: results to skip for pagination (default 0).",
        },
      },
      required: [],
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
      "discovered during implementation. Articles are PUBLISHED IMMEDIATELY by default and are visible " +
      "to agents (search/index/context) right away — no separate publish step is needed. Pass " +
      "draft: true to stage the article for later review instead; the response `note` says which " +
      "outcome occurred, and a draft can be published afterwards with knowledge_publish. " +
      "Concurrency-safe: if a create races/retries against an " +
      "existing article with the same title AND an identical body (ignoring surrounding whitespace), the " +
      "server returns that existing article idempotently (HTTP 200) instead of a 422. A same-title create " +
      "with a DIFFERENT body returns 409 title_conflict — do not retry; choose a different title or PATCH " +
      "the existing article.",
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
        draft: {
          type: "boolean",
          description:
            "Optional: stage as a draft instead of publishing on create (default false → " +
            "published immediately). Publish later with knowledge_publish.",
        },
        idempotency_key: {
          type: "string",
          description:
            "Optional: stable per-article key for idempotent capture (max 255). Re-creating " +
            "with the same key is a no-op that returns a reference to the existing article " +
            "(deduplicated; id only, not its body) instead of a partial duplicate. Use a " +
            "HIGH-ENTROPY value (e.g. a content hash) — it is a per-tenant lookup key, not a " +
            "secret, so a guessable key lets another agent in your tenant probe which keys " +
            "exist. Distinct from source_type/source_id (which mark a shared source).",
        },
        source_type: {
          type: "string",
          description:
            "Optional: advisory provenance for the originating source (e.g. 'web_article', " +
            "'newsletter'). Shared across articles from the same source; not an idempotency key.",
        },
        source_id: {
          type: "string",
          description:
            "Optional: UUID of the originating source entity (shared across articles from " +
            "that source). Pair with source_type.",
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
      "Publish draft articles, partial-success style. REQUIRES LOOPCTL_USER_KEY " +
      "(user role — orchestrator is NOT sufficient). Every valid draft is published; " +
      "each other id gets a per-id outcome instead of failing the whole call: " +
      "published, skipped (already published — idempotent — or archived/superseded), " +
      "not_found, or errored. Duplicate ids are de-duplicated and there is NO 100-id " +
      "cap (larger requests are auto-chunked server-side). The response's meta.count " +
      "is the number actually published; meta.counts has the full breakdown and " +
      "meta.results is the per-id list in request order. Safe to retry — already " +
      "published ids are skipped, not errored.",
    inputSchema: {
      type: "object",
      properties: {
        article_ids: {
          type: "array",
          items: { type: "string" },
          description:
            "Article UUIDs to publish. Any length (auto-chunked); duplicates ignored.",
        },
      },
      required: ["article_ids"],
    },
  },
  {
    name: "knowledge_unpublish",
    description:
      "Revert a published article back to draft state. The article stops being visible " +
      "in agent search/context but is not deleted — re-publish with knowledge_publish. " +
      "REQUIRES LOOPCTL_USER_KEY (user role — orchestrator role is NOT sufficient for " +
      "this destructive operation).",
    inputSchema: {
      type: "object",
      properties: {
        article_id: {
          type: "string",
          description: "The UUID of the published article to unpublish.",
        },
      },
      required: ["article_id"],
    },
  },
  {
    name: "knowledge_archive",
    description:
      "Archive an article (soft delete). The article is hidden from search, context, " +
      "and the index but the row is retained for audit/history. Works for drafts and " +
      "published articles. REQUIRES LOOPCTL_USER_KEY (user role — orchestrator role is " +
      "NOT sufficient for this destructive operation).",
    inputSchema: {
      type: "object",
      properties: {
        article_id: {
          type: "string",
          description: "The UUID of the article to archive.",
        },
      },
      required: ["article_id"],
    },
  },
  {
    name: "knowledge_delete",
    description:
      "Delete an article. Under the hood this performs the same soft-delete (archive) " +
      "as knowledge_archive — use whichever name is clearer at the call site. The row " +
      "is retained for audit; there is no hard delete. REQUIRES LOOPCTL_USER_KEY (user " +
      "role — orchestrator role is NOT sufficient for this destructive operation).",
    inputSchema: {
      type: "object",
      properties: {
        article_id: {
          type: "string",
          description: "The UUID of the article to delete.",
        },
      },
      required: ["article_id"],
    },
  },
  {
    name: "knowledge_bulk_delete",
    description:
      "Bulk soft-delete (archive) articles, partial-success style. REQUIRES LOOPCTL_USER_KEY " +
      "(user role — orchestrator is NOT sufficient). Provide EXACTLY ONE selector: " +
      "article_ids (explicit list), source_type + source_id (every active article from that " +
      "source — clean dedup cleanup), or tag + confirm:true (every active article carrying the " +
      "tag — high blast radius, so confirm:true is required). Honors soft-delete (rows move to " +
      "archived, never dropped). Each id gets a per-id outcome (archived / skipped / not_found / " +
      "errored); meta.count = archived, meta.counts/meta.results give the breakdown. Already-" +
      "archived ids are skipped (idempotent). Bounded to 5000 per call. Safe to retry.",
    inputSchema: {
      type: "object",
      properties: {
        article_ids: {
          type: "array",
          items: { type: "string" },
          description: "Explicit article UUIDs to archive (selector 1).",
        },
        source_type: {
          type: "string",
          description: "With source_id: archive every active article from this source (selector 2).",
        },
        source_id: {
          type: "string",
          description: "With source_type: the source entity UUID (selector 2).",
        },
        tag: {
          type: "string",
          description:
            "Archive every active article carrying this tag (selector 3). Requires confirm:true.",
        },
        confirm: {
          type: "boolean",
          description: "Required (true) when deleting by tag — guards the high blast radius.",
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_drafts",
    description:
      "List draft (unpublished) knowledge articles. Requires orchestrator role. " +
      "Returns paginated drafts with total_count in meta. Paginate via offset/limit " +
      "(limit honored up to 1000; a limit above the max is rejected with 400, not " +
      "silently clamped).",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "integer",
          description:
            "Max drafts per page (default 20, max 1000). A limit above the max is " +
            "rejected with 400 — not silently clamped — so offset pagination stays complete.",
          default: 20,
          minimum: 1,
          maximum: 1000,
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
  {
    name: "knowledge_okf_export",
    description:
      "Export the knowledge wiki as a portable OKF (Open Knowledge Format) v0.1 bundle — a tree of " +
      "markdown files with YAML frontmatter. Requires LOOPCTL_USER_KEY. If out_dir is given, the bundle " +
      "is written there (one .md file per concept, plus index.md/log.md) and a summary is returned; " +
      "otherwise the bundle is returned inline as {files, meta}.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          format: "uuid",
          description: "Optional: scope the export to a project (includes tenant-wide articles too).",
        },
        out_dir: {
          type: "string",
          description:
            "Optional: absolute path of a directory to write the bundle into. When omitted, the " +
            "bundle is returned inline.",
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_okf_import",
    description:
      "Import an OKF (Open Knowledge Format) v0.1 bundle from a local directory into the wiki. " +
      "Requires LOOPCTL_USER_KEY. Reserved files (index.md/log.md) are skipped; each concept is created, " +
      "or (with merge=true, the default) updated in place when it matches an existing article. Unknown " +
      "frontmatter types/keys are tolerated and preserved. Returns a per-file import report.",
    inputSchema: {
      type: "object",
      properties: {
        bundle_dir: {
          type: "string",
          description: "Absolute path of the OKF bundle directory to read .md files from.",
        },
        project_id: {
          type: "string",
          format: "uuid",
          description: "Optional: assign imported articles to a project.",
        },
        merge: {
          type: "boolean",
          description: "Update existing articles instead of skipping them (default true).",
        },
        dry_run: {
          type: "boolean",
          description: "Validate and plan only; write nothing (default false).",
        },
      },
      required: ["bundle_dir"],
    },
  },

  // Knowledge Ingestion Tools
  {
    name: "knowledge_ingest",
    description:
      "Submit a URL or raw content for knowledge extraction. " +
      "Enqueues an Oban job that fetches the content (if URL), extracts knowledge articles via LLM, " +
      "and inserts them. Extracted articles are DRAFTS by default (lower-trust LLM output, staged " +
      "for review) — unlike knowledge_create which publishes by default. Pass publish:true to " +
      "publish them on extraction. Requires orchestrator role.",
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
        publish: {
          type: "boolean",
          description:
            "Optional: publish extracted articles immediately instead of staging them as drafts (default false).",
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
              publish: {
                type: "boolean",
                description:
                  "Optional: publish this item's extracted articles immediately (default false → draft).",
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
        publish: {
          type: "boolean",
          description: "Optional batch-level default publish flag applied to items that don't specify their own.",
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

    case "knowledge_stats":
      return await knowledgeStats(args);

    case "knowledge_count":
      return await knowledgeCount(args);

    case "knowledge_facets":
      return await knowledgeFacets(args);

    case "knowledge_search":
      return await knowledgeSearch(args);

    case "knowledge_list":
      return await knowledgeList(args);

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

    case "knowledge_unpublish":
      return await knowledgeUnpublish(args);

    case "knowledge_archive":
      return await knowledgeArchive(args);

    case "knowledge_delete":
      return await knowledgeDelete(args);

    case "knowledge_bulk_delete":
      return await knowledgeBulkDelete(args);

    case "knowledge_drafts":
      return await knowledgeDrafts(args);

    case "knowledge_lint":
      return await knowledgeLint(args);

    case "knowledge_export":
      return await knowledgeExport(args);

    case "knowledge_okf_export":
      return await knowledgeOkfExport(args);

    case "knowledge_okf_import":
      return await knowledgeOkfImport(args);

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
