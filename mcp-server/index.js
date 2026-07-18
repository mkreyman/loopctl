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
import { readFileSync, writeFileSync, renameSync, lstatSync, unlinkSync } from "node:fs";
import os from "node:os";
import { fileURLToPath } from "node:url";
import path, { dirname, join } from "node:path";
import {
  projectsPath,
  ingestionJobsPath,
  llmUsagePath,
  memoryPath,
  parseJsonResponseBody,
} from "./lib/http-helpers.js";
import {
  createWitnessClient,
  resolveSthStatePath,
} from "./lib/witness-sth.js";
import {
  createGeneratedToolsRuntime,
  GENERATED_TOOL_PREFIX,
} from "./lib/generated-tools.js";

// Single source of truth for the server version: the package.json this file
// ships with (npm always includes package.json in the published tarball).
// Keeping it derived prevents the handshake version from drifting from the
// published package version.
const SERVER_VERSION = JSON.parse(
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), "package.json"), "utf8")
).version;

// ---------------------------------------------------------------------------
// HTTP helper — witness protocol state
// ---------------------------------------------------------------------------

// The witness protocol requires clients to echo back the last-known Signed Tree
// Head (STH) on every authenticated request. The mechanics live in
// ./lib/witness-sth.js (shared with the test suite):
//
//   * On the very first request from a caller that has never seen an STH we send
//     `X-Loopctl-STH-Bootstrap: true` to receive the current STH in the
//     `x-loopctl-current-sth` response header.
//   * That STH is cached AND persisted to a small per-server state file, so a
//     FRESH MCP process (new Claude session) loads it and sends a real
//     `X-Loopctl-Last-Known-STH` on its first request — never tripping the
//     one-time bootstrap-grace 412 (`witness_bootstrap_already_consumed`, #298).
//   * If a request still hits that bootstrap-grace 412 (state file missing or
//     corrupt), the client caches the STH from the 412's `x-loopctl-current-sth`
//     header and RETRIES the SAME request exactly ONCE — transparently — so the
//     tool call succeeds. The witness plug halts before the operation runs, so
//     retrying a witness 412 is side-effect-safe even for POSTs.
//
// The state file location defaults to a per-(server + key) file under the OS temp
// dir and can be overridden with LOOPCTL_STH_STATE_PATH. All file I/O degrades
// gracefully (missing/corrupt/unwritable/symlinked → in-memory cache + the
// transparent retry above). The write is atomic + symlink-safe (temp + rename).
const WITNESS_FS = { readFileSync, writeFileSync, renameSync, lstatSync, unlinkSync };

// Default per-request HTTP timeout. Individual calls may pass a SHORTER budget via
// `apiCall(..., { timeoutMs })` — e.g. the init-time generated-tools listing fetch,
// which must degrade to static tools quickly rather than block connection setup.
const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;

// One witness client PER API KEY (#298 review HIGH-2): the STH is per-tenant and
// each key resolves to a tenant server-side, so distinct keys must NOT share an
// in-memory cache or a state file (a collision causes spurious 409s + false
// divergence telemetry). The state file is keyed by sha256(serverUrl + ":" + key)
// — a non-secret hash; the key never hits disk in plaintext.
const witnessClients = new Map();

function witnessClientFor(apiKey) {
  let client = witnessClients.get(apiKey);
  if (!client) {
    const statePath = resolveSthStatePath({ env: process.env, os, path, apiKey });
    client = createWitnessClient({
      statePath,
      fs: WITNESS_FS,
      getuid: typeof process.getuid === "function" ? () => process.getuid() : undefined,
      pid: process.pid,
      timeoutMs: DEFAULT_REQUEST_TIMEOUT_MS,
    });
    witnessClients.set(apiKey, client);
  }
  return client;
}

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

async function apiCall(method, path, body, keyOverride, { exactKey = false, timeoutMs } = {}) {
  const url = `${getBaseUrl()}${path}`;
  // Secret-managing tools pass exactKey:true so the request uses the EXACT
  // role-pinned key (LOOPCTL_USER_KEY) and does NOT fall back to the global
  // LOOPCTL_API_KEY override — a secret op must never silently run under a
  // non-user global key (review #12).
  const key = exactKey ? keyOverride : resolveKey(keyOverride);

  if (!key) {
    return {
      error: true,
      status: 0,
      body: exactKey
        ? "No user-role API key configured. Set LOOPCTL_USER_KEY to a user-role key to manage LLM configuration."
        : "No API key configured. Set LOOPCTL_API_KEY, LOOPCTL_ORCH_KEY, or LOOPCTL_AGENT_KEY.",
    };
  }

  const headers = {
    Authorization: `Bearer ${key}`,
    "Content-Type": "application/json",
    Accept: "application/json",
  };

  const serializedBody =
    body !== undefined && body !== null ? JSON.stringify(body) : undefined;

  // The witness client injects the STH header, caches + persists any STH the
  // server returns, and transparently retries a bootstrap-grace 412 ONCE (see
  // ./lib/witness-sth.js and the module comment above). It returns the final
  // attempt's Response; we keep body parsing / error shaping here.
  let response;
  try {
    response = await witnessClientFor(key).send({ url, method, headers, serializedBody, timeoutMs });
  } catch (err) {
    if (err.name === "TimeoutError") {
      const secs = Math.max(1, Math.round((timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS) / 1000));
      return { error: true, status: 0, body: `Request timed out after ${secs}s` };
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
    // A JSON content-type is no guarantee of a well-formed body: a transient Fly
    // edge 502/503 or a truncated/empty response can arrive with the JSON header.
    // Read the raw text and parse defensively (shared with the test suite via
    // lib/http-helpers.js) so a malformed body becomes a structured MCP error
    // instead of an unhandled throw from response.json().
    const raw = await response.text();
    const outcome = parseJsonResponseBody(raw, response.status);
    if (outcome.error) {
      return outcome;
    }
    responseBody = outcome.parsed;
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

/**
 * Unauthenticated request helper for genuinely public endpoints (currently
 * only POST /api/v1/signup). No Authorization header is sent — the public
 * signup POST carries no witness header either (US-26.7.1), so this
 * bypasses `witnessClientFor` entirely and calls `fetch` directly. Response
 * parsing mirrors `apiCall`'s so callers can pass the result straight to
 * `toContent`/`toContentCompact`.
 */
async function publicApiCall(method, path, body) {
  const url = `${getBaseUrl()}${path}`;
  const headers = { "Content-Type": "application/json", Accept: "application/json" };
  const serializedBody =
    body !== undefined && body !== null ? JSON.stringify(body) : undefined;

  let response;
  try {
    response = await fetch(url, {
      method,
      headers,
      body: serializedBody,
      signal: AbortSignal.timeout(30_000),
    });
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
    const raw = await response.text();
    const outcome = parseJsonResponseBody(raw, response.status);
    if (outcome.error) {
      return outcome;
    }
    responseBody = outcome.parsed;
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
 * A modest DEFAULT page size keeps unprompted responses small, but an explicit
 * `limit` is honored up to the server's max (500) so story enumeration paginates
 * honestly instead of silently capping at 20 and skipping rows on offset advance.
 */
const DEFAULT_STORY_PAGE_SIZE = 20;
const SERVER_MAX_STORY_PAGE_SIZE = 500;

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

/**
 * Surface a server-emitted BYO-LLM `remediation` PROMINENTLY as a leading text
 * block. A stranger agent that calls knowledge_ingest / knowledge_search /
 * knowledge_context BEFORE provisioning its keys then reads the exact next step
 * in the tool result — call set_llm_config — instead of hunting through raw JSON.
 *
 * The remediation lives in one of two places depending on the failure shape:
 *   - ingest no-key 422  → result.body.error.remediation (code "no_api_key")
 *   - search/context degrade → result.meta.remediation (fallback_reason
 *     "no_embedding_key"); the request still returns 200 keyword-only results.
 *
 * Returns a notice string, or null when there is no LLM remediation to surface.
 */
function llmRemediationNotice(result) {
  const rem =
    (result &&
      result.error === true &&
      result.body &&
      result.body.error &&
      result.body.error.remediation) ||
    (result && result.meta && result.meta.remediation) ||
    null;

  if (!rem || rem.action !== "configure_llm") return null;

  const missing = Array.isArray(rem.missing) ? rem.missing.join(", ") : rem.missing;
  return (
    `ACTION REQUIRED — BYO LLM key not configured (missing: ${missing}). ` +
    `${rem.message || ""} Provision it ONCE with the ${rem.mcp_tool} MCP tool, e.g. ` +
    `${rem.example} (REST: ${rem.api}). Requires your user-role key (LOOPCTL_USER_KEY). ` +
    `Docs: ${rem.docs}`
  ).replace(/\s+/g, " ").trim();
}

/**
 * toContent, but with any BYO-LLM remediation notice prepended so it is the first
 * thing the agent reads. Preserves isError from the underlying result.
 */
function withRemediationNotice(result) {
  const base = toContent(result);
  const notice = llmRemediationNotice(result);
  if (!notice) return base;
  return { ...base, content: [{ type: "text", text: notice }, ...base.content] };
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

// --- Project Tools ---

async function getTenant() {
  const result = await apiCall("GET", "/api/v1/tenants/me");
  return toContent(result);
}

async function listProjects(args = {}) {
  // Query-string building lives in lib/http-helpers.js so the test suite exercises
  // the same page/page_size logic the server ships (#247, mcp-01).
  const result = await apiCall("GET", projectsPath(args));
  return toContent(result);
}

async function resolveProject({ slug, repo_url, name } = {}) {
  // Cheap repo -> project_id resolution (loopctl #411 Gap 1). Server tries
  // slug -> repo_url -> name and returns the first match; agent-role read.
  const params = new URLSearchParams();
  if (slug) params.set("slug", slug);
  if (repo_url) params.set("repo_url", repo_url);
  if (name) params.set("name", name);
  const result = await apiCall(
    "GET",
    `/api/v1/projects/resolve?${params}`,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
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

async function createKbScope({ name, slug, repo_url, description, tech_stack }) {
  const body = { name, slug };
  if (repo_url) body.repo_url = repo_url;
  if (description) body.description = description;
  if (tech_stack) body.tech_stack = tech_stack;
  // Uses the AGENT key (not ORCH): a KB scope is agent-createable on the KB tier — that is
  // the whole point. The server forces kind: :kb; a body-supplied kind is ignored.
  const result = await apiCall("POST", "/api/v1/kb-scopes", body, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function archiveKbScope({ project_id }) {
  // Reversible soft-delete of an agent-owned :kb scope on the AGENT key; frees its
  // max_projects slot. The server rejects a :work project (422). Reverse with restore_kb_scope.
  const result = await apiCall(
    "DELETE",
    `/api/v1/kb-scopes/${project_id}`,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

async function restoreKbScope({ project_id }) {
  // Re-activate an archived :kb scope on the AGENT key (re-consumes a max_projects slot;
  // 422 if at the cap). The server rejects a :work project (422).
  const result = await apiCall(
    "POST",
    `/api/v1/kb-scopes/${project_id}/restore`,
    {},
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

async function channelPost({ project_id, body, key, refs }) {
  // Repo Coordination Bus (Epic 39): post a coordination message to a channel
  // (a channel IS a project_id — a work project or a kb scope). Agent-role, RLS
  // tenant-scoped — posting to your own tenant's channel is coordination, NOT
  // self-approval (owner decision #331), so it carries no chain-of-custody authority.
  const payload = { project_id, body };
  if (key) payload.key = key;
  if (refs) payload.refs = refs;
  // host + session_id are proxy-filled (NOT caller args). host from os.hostname();
  // session_id from CLAUDE_SESSION_ID (the SAME id SessionStart sees) so US-39.6
  // self-dedup can skip a session's own echoed posts. Omit session_id entirely when
  // unset — it is client-supplied + informational, never a security dependency.
  payload.host = os.hostname();
  if (process.env.CLAUDE_SESSION_ID) payload.session_id = process.env.CLAUDE_SESSION_ID;
  const result = await apiCall(
    "POST",
    "/api/v1/channel/posts",
    payload,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

async function channelRecent({ project_id, since, limit }) {
  // Read recent coordination posts for a channel (project_id) on the AGENT key.
  // Oracle-safe read: returns the tenant's own channel only (RLS). `since` is a full
  // ISO8601 instant (date-only is ignored server-side); limit defaults to 25, max 100.
  const params = new URLSearchParams();
  if (project_id) params.set("project_id", project_id);
  if (since) params.set("since", since);
  if (limit) params.set("limit", limit);
  const result = await apiCall(
    "GET",
    `/api/v1/channel/posts?${params}`,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
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
  params.set(
    "limit",
    String(Math.min(limit ?? DEFAULT_STORY_PAGE_SIZE, SERVER_MAX_STORY_PAGE_SIZE)),
  );
  if (offset != null) params.set("offset", String(offset));
  if (include_token_totals) params.set("include_token_totals", "true");

  const result = await apiCall("GET", `/api/v1/stories?${params}`);
  return toContentCompact(result);
}

async function listReadyStories({ project_id, page, page_size }) {
  // /stories/ready paginates by page/page_size — the old `limit` param was
  // silently ignored by the server, capping callers at the first page.
  const params = new URLSearchParams({ project_id });
  if (page != null) params.set("page", String(page));
  if (page_size != null)
    params.set("page_size", String(Math.min(page_size, SERVER_MAX_STORY_PAGE_SIZE)));

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

async function getStoryTokenUsage({ story_id, page, page_size }) {
  const params = new URLSearchParams();
  if (page != null) params.set("page", String(page));
  if (page_size != null) params.set("page_size", String(page_size));
  const query = params.toString() ? `?${params}` : "";
  const result = await apiCall("GET", `/api/v1/stories/${story_id}/token-usage${query}`);
  return toContent(result);
}

async function getCostAnomalies({ project_id, page, page_size }) {
  const params = new URLSearchParams();
  if (project_id) params.set("project_id", project_id);
  if (page != null) params.set("page", String(page));
  if (page_size != null) params.set("page_size", String(page_size));

  const query = params.toString() ? `?${params}` : "";
  const result = await apiCall("GET", `/api/v1/cost-anomalies${query}`);
  return toContent(result);
}

async function getIngestionAnomalies({
  source_type,
  anomaly_type,
  resolved,
  include_archived,
  page,
  page_size,
}) {
  const params = new URLSearchParams();
  if (source_type) params.set("source_type", source_type);
  if (anomaly_type) params.set("anomaly_type", anomaly_type);
  if (resolved != null) params.set("resolved", String(resolved));
  if (include_archived != null) params.set("include_archived", String(include_archived));
  if (page != null) params.set("page", String(page));
  if (page_size != null) params.set("page_size", String(page_size));

  const query = params.toString() ? `?${params}` : "";
  // Orchestrator-gated endpoint (RequireRole :orchestrator). Pass the ORCH key
  // explicitly so a misconfigured single agent-role LOOPCTL_API_KEY fails loudly
  // rather than drifting into an undiagnosable 403.
  const result = await apiCall(
    "GET",
    `/api/v1/ingestion-anomalies${query}`,
    undefined,
    process.env.LOOPCTL_ORCH_KEY
  );
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

async function knowledgeGraph({ article_id, depth, project_id }) {
  const params = new URLSearchParams();
  params.set("article_id", article_id);
  if (depth != null) params.set("depth", String(depth));
  if (project_id) params.set("project_id", project_id);
  const result = await apiCall(
    "GET",
    `/api/v1/knowledge/graph?${params}`,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

async function knowledgeSuggestLinks({ article_id, limit, threshold }) {
  const params = new URLSearchParams();
  if (limit != null) params.set("limit", String(limit));
  if (threshold != null) params.set("threshold", String(threshold));
  const qs = params.toString();
  const base = `/api/v1/knowledge/articles/${article_id}/suggested_links`;
  const result = await apiCall(
    "GET",
    qs ? `${base}?${qs}` : base,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

async function knowledgeDistantPairs({ min_distance, max_distance, bridge_path, limit, offset }) {
  const params = new URLSearchParams();
  if (min_distance != null) params.set("min_distance", String(min_distance));
  if (max_distance != null) params.set("max_distance", String(max_distance));
  if (bridge_path === true) params.set("bridge_path", "true");
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  const qs = params.toString();
  const path = qs ? `/api/v1/knowledge/pairs?${qs}` : "/api/v1/knowledge/pairs";
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeNovelty({ ideas, texts, prior_tag }) {
  // Accept either shape (#169): `ideas` (strings or objects) or `texts` (strings).
  const body = {};
  if (ideas !== undefined) body.ideas = ideas;
  if (texts !== undefined) body.texts = texts;
  if (prior_tag) body.prior_tag = prior_tag;
  const result = await apiCall("POST", "/api/v1/knowledge/novelty", body, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeRandomWalk({ start_id, length }) {
  const params = new URLSearchParams();
  params.set("start_id", start_id);
  if (length != null) params.set("length", String(length));
  const result = await apiCall(
    "GET",
    `/api/v1/knowledge/walk?${params}`,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
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
  // If search silently degraded to keyword-only for a missing embedding key, the
  // server attaches meta.remediation — surface it PROMINENTLY so the agent knows to
  // call set_llm_config to enable semantic ranking.
  return withRemediationNotice(result);
}

async function knowledgeHybridSearch({ query, project_id, category, tags, match, limit, offset }) {
  const bodyPayload = { query };
  if (project_id) bodyPayload.project_id = project_id;
  if (category) bodyPayload.category = category;
  if (tags) bodyPayload.tags = tags;
  if (match) bodyPayload.match = match;
  if (limit != null) bodyPayload.limit = limit;
  if (offset != null) bodyPayload.offset = offset;

  const result = await apiCall(
    "POST",
    "/api/v1/knowledge/hybrid_search",
    bodyPayload,
    process.env.LOOPCTL_AGENT_KEY,
  );
  // meta.provenance ("curated" | "retrieved") is the load-bearing field and rides
  // through toContent verbatim. Same missing-embedding-key remediation surfacing as
  // knowledge_search, since hybrid runs the combined pool underneath.
  return withRemediationNotice(result);
}

async function knowledgeProgressiveIndex({ topic, category, limit }) {
  const params = new URLSearchParams();
  if (topic != null) params.set("topic", topic);
  if (category) params.set("category", category);
  if (limit != null) params.set("limit", String(limit));

  const result = await apiCall(
    "GET",
    `/api/v1/knowledge/progressive_index?${params}`,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

async function knowledgeProgressiveDrill({ article_id }) {
  const result = await apiCall(
    "GET",
    `/api/v1/knowledge/progressive/${article_id}`,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
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

async function knowledgeContext({
  query,
  project_id,
  story_id,
  limit,
  recency_weight,
  memory_types,
  agents,
  conversation_id,
}) {
  const params = new URLSearchParams({ query });
  if (project_id) params.set("project_id", project_id);
  if (story_id) params.set("story_id", story_id);
  if (limit != null) params.set("limit", String(limit));
  if (recency_weight != null) params.set("recency_weight", String(recency_weight));
  // Agent-memory scoping (comma-separated lists are OR'd; conversation_id is exact).
  if (memory_types) params.set("memory_types", Array.isArray(memory_types) ? memory_types.join(",") : memory_types);
  if (agents) params.set("agents", Array.isArray(agents) ? agents.join(",") : agents);
  if (conversation_id) params.set("conversation_id", conversation_id);

  const result = await apiCall("GET", `/api/v1/knowledge/context?${params}`, null, process.env.LOOPCTL_AGENT_KEY);
  // Same as knowledge_search: surface a missing-embedding-key remediation prominently.
  return withRemediationNotice(result);
}

async function knowledgeCreate({
  title,
  body,
  category,
  tags,
  project_id,
  draft,
  force,
  source_type,
  source_id,
  idempotency_key,
  metadata,
}) {
  const payload = { title, body };
  if (category) payload.category = category;
  if (tags) payload.tags = tags;
  if (project_id) payload.project_id = project_id;
  if (source_type) payload.source_type = source_type;
  if (source_id) payload.source_id = source_id;
  if (idempotency_key) payload.idempotency_key = idempotency_key;
  if (metadata) payload.metadata = metadata;

  // Articles publish on create by default for every role (including agent), so a
  // plain create routes through the agent key and is immediately visible. Pass
  // draft:true to stage it for later review instead — publish it afterwards with
  // knowledge_publish.
  if (draft) payload.draft = true;

  // The server-side novelty gate dedups the proposal against the corpus (verdict in
  // the response `gate`). force:true bypasses it.
  if (force) payload.force = true;

  const result = await apiCall(
    "POST",
    "/api/v1/articles",
    payload,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

// In-place edit of an existing article (#331). PATCH preserves the ID; only the
// provided fields change. Agent role — KB-content curation, visibility-scoped
// server-side (another agent's private/owner memory 404s).
async function knowledgeUpdate({ article_id, title, body, category, tags, metadata }) {
  const payload = {};
  if (title != null) payload.title = title;
  if (body != null) payload.body = body;
  if (category != null) payload.category = category;
  if (tags != null) payload.tags = tags;
  if (metadata != null) payload.metadata = metadata;

  const result = await apiCall(
    "PATCH",
    `/api/v1/articles/${article_id}`,
    payload,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

// --- Agent Memory Tools (US-28.4) ---
//
// memory_* is YOUR own scoped, private, accumulated working state — recall
// across sessions, running notes, in-flight task context. knowledge_* is the
// curated, shared wiki. Scope (tenant_id/subject_id) is resolved SERVER-SIDE
// from the API key (US-28.3) — these tools never accept or forward a
// tenant_id/subject_id, so there is no NON-SUPERADMIN way to express a
// cross-scope read/write here even by mistake. (The one carve-out:
// memory_list's `all_subjects` boolean IS a cross-subject read, but it is
// enforced server-side and a no-op for a non-superadmin key — see its
// description below.) Routes through the shared apiCall/witness client
// (same as every other write tool), so witness/STH persistence + the
// transparent 412 self-heal on a fresh MCP process apply automatically
// (AC-28.4.3) — no bespoke witness code needed.

async function memoryRemember({
  tier,
  text,
  confidence,
  tags,
  source_session_id,
  session_id,
  role,
  content,
  expires_at,
  metadata,
}) {
  const payload = {};
  if (tier) payload.tier = tier;
  if (text != null) payload.text = text;
  if (confidence != null) payload.confidence = confidence;
  if (tags) payload.tags = tags;
  if (source_session_id) payload.source_session_id = source_session_id;
  if (session_id) payload.session_id = session_id;
  if (role) payload.role = role;
  if (content != null) payload.content = content;
  if (expires_at) payload.expires_at = expires_at;
  if (metadata != null) payload.metadata = metadata;

  const result = await apiCall(
    "POST",
    "/api/v1/memory",
    payload,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

async function memoryRecall({ query, limit, include_superseded }) {
  const payload = { query };
  if (limit != null) payload.limit = limit;
  if (include_superseded != null) payload.include_superseded = include_superseded;

  const result = await apiCall(
    "POST",
    "/api/v1/memory/recall",
    payload,
    process.env.LOOPCTL_AGENT_KEY,
  );
  // Surface meta (fallback/reason/total_count/underfilled) so the caller can tell
  // a degraded recall from a genuinely empty scope (AC-28.4.4) — toContent already
  // preserves the full result (data + meta), we just keep this call explicit.
  return toContent(result);
}

async function recallContext({ query, project_id, limit }) {
  // Merged recall (#411 Gap 2): ONE round-trip returning the re-ranked
  // global ∪ active-project union of long-term MEMORY and KNOWLEDGE. Scope
  // (tenant_id/subject_id) is derived server-side from the agent key; project_id is
  // the partition key (merges global with that project on BOTH sides).
  const payload = { query };
  if (project_id) payload.project_id = project_id;
  if (limit != null) payload.limit = limit;

  const result = await apiCall(
    "POST",
    "/api/v1/recall",
    payload,
    process.env.LOOPCTL_AGENT_KEY,
  );
  // Surface both per-source metas (memory fallback/underfilled + knowledge degraded)
  // so the caller can tell a degraded recall from a genuinely empty scope.
  return toContent(result);
}

async function memoryList({ limit, offset, include_superseded, all_subjects }) {
  // all_subjects is superadmin-only server-side; a non-superadmin key sending
  // this is ignored (falls back to its own subject) rather than erroring — the
  // one deliberate cross-subject read this MCP surface can express (module
  // comment above), and only for a superadmin caller.
  const path = memoryPath({ limit, offset, include_superseded, all_subjects });
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_AGENT_KEY);
  // Surface meta.total_count/limit/offset (AC-28.4.4).
  return toContent(result);
}

async function memoryForget({ id }) {
  // Path-injection guard (mirrors knowledgeAgentUsage's UUID_RE check below).
  if (typeof id !== "string" || !UUID_RE.test(id)) {
    return {
      content: [{ type: "text", text: "Error: id must be a canonical UUID (8-4-4-4-12 hex)." }],
      isError: true,
    };
  }

  const result = await apiCall(
    "DELETE",
    `/api/v1/memory/${id}`,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

async function memoryPromote({ session_id }) {
  const payload = { session_id };
  const result = await apiCall(
    "POST",
    "/api/v1/memory/promote",
    payload,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

async function memoryGraduate({ memory_id, re_scope }) {
  // Explicit memory→knowledge graduation (#411 Gap 3). Scope (tenant_id/subject_id)
  // is derived server-side from the agent key; memory_id identifies the caller's OWN
  // memory to graduate. The graduated article stays OWNER-visible (not peer-readable).
  // re_scope: "global" widens only the project partition (project → tenant-wide), NOT
  // visibility, and only on the memory's first graduation.
  const payload = { memory_id };
  if (re_scope) payload.re_scope = re_scope;

  const result = await apiCall(
    "POST",
    "/api/v1/memory/graduate",
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

async function knowledgeBulkUnpublish({ article_ids }) {
  const result = await apiCall(
    "POST",
    "/api/v1/knowledge/bulk-unpublish",
    { article_ids },
    process.env.LOOPCTL_USER_KEY
  );

  // Partial success returns 200 even when nothing unpublished. Surface a warning
  // so the agent doesn't treat not_found/errored ids as success.
  const counts = result?.meta?.counts;
  if (counts && (counts.not_found > 0 || counts.errored > 0)) {
    const warning =
      `WARNING: bulk-unpublish was partial — unpublished ${counts.unpublished}, ` +
      `skipped ${counts.skipped}, not_found ${counts.not_found}, errored ${counts.errored} ` +
      `(of ${counts.requested} requested). Inspect meta.results for per-id outcomes; ` +
      `not_found/errored ids were NOT unpublished.`;
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

// #331: single-article archive is agent-role KB curation (reversible soft delete,
// audited, visibility-scoped server-side).
async function knowledgeArchive({ article_id }) {
  const result = await apiCall(
    "POST",
    `/api/v1/articles/${article_id}/archive`,
    null,
    process.env.LOOPCTL_AGENT_KEY
  );
  return toContent(result);
}

// #331: soft-delete (archive) is agent-role KB curation, same as knowledge_archive.
async function knowledgeDelete({ article_id }) {
  const result = await apiCall(
    "DELETE",
    `/api/v1/articles/${article_id}`,
    null,
    process.env.LOOPCTL_AGENT_KEY
  );
  return toContent(result);
}

async function knowledgeBulkDelete({
  article_ids,
  source_type,
  source_id,
  tag,
  confirm,
  dry_run,
  hard,
  token,
  confirm_hash,
}) {
  const payload = {};
  if (article_ids) payload.article_ids = article_ids;
  if (source_type) payload.source_type = source_type;
  if (source_id) payload.source_id = source_id;
  if (tag) payload.tag = tag;
  if (confirm) payload.confirm = confirm;
  // US-27.12: dry-run preview + irreversible hard delete via a single-use frozen
  // token. dry_run=true mutates nothing (returns meta.would_affect; for the hard
  // path a single-use meta.token); hard=true + token performs the FK-correct
  // IRREVERSIBLE delete over the frozen id-set. Oversized selectors echo
  // meta.confirm_hash for re-confirm-on-drift instead of a token.
  if (dry_run) payload.dry_run = true;
  if (hard) payload.hard = true;
  if (token) payload.token = token;
  if (confirm_hash) payload.confirm_hash = confirm_hash;

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
  // Pass `limit` through verbatim (like knowledge_list/index/search) so the server
  // honors it up to its max page size, clamping above it server-side rather than
  // silently clamping client-side (which would truncate draft enumeration).
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  if (project_id) params.set("project_id", project_id);
  const path = `/api/v1/knowledge/drafts?${params.toString()}`;
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function knowledgeConflicts({ limit, offset }) {
  const params = new URLSearchParams();
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  const qs = params.toString();
  const path = qs
    ? `/api/v1/knowledge/conflicts?${qs}`
    : "/api/v1/knowledge/conflicts";
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function knowledgeResolveConflict({
  source_article_id,
  target_article_id,
  disposition,
  authoritative_article_id,
  classification,
  evidence,
  confidence,
}) {
  const payload = { source_article_id, target_article_id, disposition };
  if (authoritative_article_id) payload.authoritative_article_id = authoritative_article_id;
  if (classification) payload.classification = classification;
  if (evidence) payload.evidence = evidence;
  if (confidence) payload.confidence = confidence;
  const result = await apiCall(
    "POST",
    "/api/v1/knowledge/conflicts/resolve",
    payload,
    process.env.LOOPCTL_AGENT_KEY,
  );
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
  // A keyless tenant gets a 422 (code no_api_key) carrying a remediation — surface it
  // prominently so a first-time agent knows to call set_llm_config before ingesting.
  return withRemediationNotice(result);
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
  // Batch ingest gates on the Anthropic key up front too — a keyless tenant gets a
  // 422 with the same remediation; surface it prominently.
  return withRemediationNotice(result);
}

async function knowledgeIngestionJobs(args = {}) {
  // Query-string building lives in lib/http-helpers.js so the test suite exercises
  // the same limit/offset/since_days logic the server ships (#248, mcp-02).
  const result = await apiCall(
    "GET",
    ingestionJobsPath(args),
    null,
    process.env.LOOPCTL_ORCH_KEY,
  );
  return toContent(result);
}

// --- Per-tenant BYO LLM config + usage (Epic 28 residual, #179) ---

async function llmConfig() {
  // Reading/writing the tenant LLM config touches a stored secret → EXACT user
  // key only (bypass the global LOOPCTL_API_KEY override; fail fast if unset).
  const result = await apiCall(
    "GET",
    "/api/v1/tenants/me/llm-config",
    null,
    process.env.LOOPCTL_USER_KEY,
    { exactKey: true },
  );
  return toContent(result);
}

async function setLlmConfig({
  api_key,
  extraction_model,
  classification_model,
  merge_model,
  embedding_api_key,
  embedding_model,
}) {
  const body = {};
  if (api_key != null) body.api_key = api_key;
  if (extraction_model !== undefined) body.extraction_model = extraction_model;
  if (classification_model !== undefined) body.classification_model = classification_model;
  if (merge_model !== undefined) body.merge_model = merge_model;
  if (embedding_api_key != null) body.embedding_api_key = embedding_api_key;
  if (embedding_model !== undefined) body.embedding_model = embedding_model;
  // PATCH (partial-merge) + EXACT user key (review #12, #13).
  const result = await apiCall(
    "PATCH",
    "/api/v1/tenants/me/llm-config",
    body,
    process.env.LOOPCTL_USER_KEY,
    { exactKey: true },
  );
  return toContent(result);
}

async function knowledgeLlmUsage(args = {}) {
  // Query-string building lives in lib/http-helpers.js so the test suite exercises
  // the same from/to/limit/offset logic the server ships.
  const result = await apiCall(
    "GET",
    llmUsagePath(args),
    null,
    process.env.LOOPCTL_ORCH_KEY,
  );
  return toContent(result);
}

// --- Knowledge Analytics Tools (orch key) ---

async function knowledgeAnalyticsTop({ limit, offset, since_days, access_type } = {}) {
  const params = new URLSearchParams();
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  if (since_days != null) params.set("since_days", String(since_days));
  if (access_type) params.set("access_type", access_type);
  const qs = params.toString();
  const path = qs
    ? `/api/v1/knowledge/analytics/top-articles?${qs}`
    : "/api/v1/knowledge/analytics/top-articles";
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function knowledgeRetrievalMetrics({ limit, offset } = {}) {
  const params = new URLSearchParams();
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  const qs = params.toString();
  const path = qs
    ? `/api/v1/knowledge/analytics/retrieval-metrics?${qs}`
    : "/api/v1/knowledge/analytics/retrieval-metrics";
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_ORCH_KEY);
  return toContent(result);
}

async function knowledgeCurationLog({ kind, since, limit, offset } = {}) {
  const params = new URLSearchParams();
  if (kind) params.set("kind", kind);
  if (since) params.set("since", since);
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  const qs = params.toString();
  const path = qs
    ? `/api/v1/knowledge/curation-log?${qs}`
    : "/api/v1/knowledge/curation-log";
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

async function knowledgeUnusedArticles({ days_unused, limit, offset } = {}) {
  const params = new URLSearchParams();
  if (days_unused != null) params.set("days_unused", String(days_unused));
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
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
  // The export endpoint is role:user — use LOOPCTL_USER_KEY. (LOOPCTL_ORCH_KEY is
  // orchestrator role, which is BELOW user in the hierarchy and would 403.) The
  // endpoint streams a gzipped tar (`application/gzip`), so save it as `.tar.gz`.
  const downloadCmd = `curl -H "Authorization: Bearer $LOOPCTL_USER_KEY" "${baseUrl}${basePath}" -o knowledge-export.tar.gz`;
  return {
    content: [{
      type: "text",
      text: JSON.stringify({
        message:
          "Knowledge export streams a bounded-memory gzipped tar (.tar.gz). Use the curl " +
          "command below to download it directly. Requires a user-role key " +
          "(LOOPCTL_USER_KEY); extract with `tar -xzf knowledge-export.tar.gz`.",
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

// US-26.7.1: public, agent-rooted (KB-tier) self-signup. No API key required —
// this creates the tenant AND the key. The resulting tenant is KB-tier only
// (knowledge ingest/search/curate on the caller's own BYO LLM keys); the
// work-breakdown / chain-of-custody surface requires a separate,
// human-anchored WebAuthn signup ceremony at https://loopctl.com/signup.
async function signup({ name, slug, email }) {
  const result = await publicApiCall("POST", "/api/v1/signup", { name, slug, email });
  return toContent(result);
}

// US-26.7.2: opt-in WebAuthn trust-tier upgrade ceremony (agent_rooted ->
// human_anchored) + authenticator revocation. All four require the EXACT
// user-role key (LOOPCTL_USER_KEY) + ownership of `tenant_id` — mirroring
// set_llm_config's exactKey:true pattern, since these mutate the tenant's
// root of trust. NOT headless: completing enrollment/revocation requires an
// INTERACTIVE WebAuthn client (a browser or a native FIDO2 library) with a
// human present to touch the hardware authenticator — an agent alone cannot
// produce a valid attestation or assertion, by design (see
// docs/chain-of-custody-v2.md §9).
async function requestAuthenticatorChallenge({ tenant_id }) {
  const result = await apiCall(
    "POST",
    `/api/v1/tenants/${tenant_id}/authenticators/challenge`,
    {},
    process.env.LOOPCTL_USER_KEY,
    { exactKey: true },
  );
  return toContent(result);
}

async function enrollAuthenticator({
  tenant_id,
  challenge_id,
  attestation_object,
  client_data_json,
  credential_id,
  friendly_name,
  reauth_assertion,
}) {
  const body = { challenge_id, attestation_object, client_data_json, credential_id };
  if (friendly_name != null) body.friendly_name = friendly_name;
  if (reauth_assertion != null) body.reauth_assertion = reauth_assertion;

  const result = await apiCall(
    "POST",
    `/api/v1/tenants/${tenant_id}/authenticators`,
    body,
    process.env.LOOPCTL_USER_KEY,
    { exactKey: true },
  );
  return toContent(result);
}

async function requestAuthenticatorRevokeChallenge({ tenant_id }) {
  const result = await apiCall(
    "POST",
    `/api/v1/tenants/${tenant_id}/authenticators/revoke-challenge`,
    {},
    process.env.LOOPCTL_USER_KEY,
    { exactKey: true },
  );
  return toContent(result);
}

async function revokeAuthenticator({ tenant_id, authenticator_id, webauthn_assertion }) {
  const result = await apiCall(
    "DELETE",
    `/api/v1/tenants/${tenant_id}/authenticators/${authenticator_id}`,
    { webauthn_assertion },
    process.env.LOOPCTL_USER_KEY,
    { exactKey: true },
  );
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
    description:
      "List projects in the current tenant. Paginated (page/page_size); advance " +
      "`page` to enumerate all projects. Response includes pagination meta.",
    inputSchema: {
      type: "object",
      properties: {
        page: { type: "integer", description: "Page number (default 1)." },
        page_size: { type: "integer", description: "Items per page (default 20)." },
      },
      required: [],
    },
  },
  {
    name: "resolve_project",
    description:
      "Resolve a repo to its project in one cheap call. Provide any of slug, " +
      "repo_url (git@github.com:owner/repo.git, https://github.com/owner/repo, " +
      "and bare owner/repo all match), or name. Precedence: slug > repo_url > " +
      "name; first match wins. Returns the project (use its id to scope " +
      "captures/recall), 404 not_found if nothing matches, 422 no_identifier " +
      "if none supplied.",
    inputSchema: {
      type: "object",
      properties: {
        slug: {
          type: "string",
          description: "Exact project slug (often the repo basename).",
        },
        repo_url: {
          type: "string",
          description: "Git remote URL or bare owner/repo.",
        },
        name: {
          type: "string",
          description: "Exact project name (case-insensitive).",
        },
      },
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
    name: "create_kb_scope",
    description:
      "Create a knowledge-only project scope (kind: kb) for the current tenant. Unlike create_project (work project, orchestrator+ / human-anchored), this is available to an agent-rooted (KB-tier) tenant with an agent key: a kb scope carries NO chain-of-custody / work-breakdown surface (it cannot host epics/stories/dispatch/ui-tests), it exists only to partition knowledge articles by repo so captured/created articles can be project-scoped. Then resolve_project by its repo_url/slug and pass the returned id as project_id on article/knowledge writes. Counts toward the tenant's max_projects budget.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Scope name (often the repo name)." },
        slug: { type: "string", description: "URL-safe slug (often the repo basename)." },
        repo_url: {
          type: "string",
          description: "Repo URL, so resolve_project can map a repo to this scope.",
        },
        description: { type: "string", description: "Scope description." },
        tech_stack: { type: "string", description: "Tech stack summary." },
      },
      required: ["name", "slug"],
    },
  },
  {
    name: "archive_kb_scope",
    description:
      "Archive (reversible soft-delete) a knowledge-only project scope (kind: kb) you own, on the agent key. Frees the scope's slot in the tenant's max_projects budget so you can reclaim KB-scope capacity — the reverse of create_kb_scope. Its articles remain readable/writable; restore_kb_scope re-activates it. Rejects a kind: work project (422) — archiving a work project stays human-anchored. Idempotent on an already-archived scope.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: { type: "string", description: "UUID of the :kb scope to archive." },
      },
      required: ["project_id"],
    },
  },
  {
    name: "restore_kb_scope",
    description:
      "Restore (re-activate) an archived knowledge-only project scope (kind: kb) you own, on the agent key — the reverse of archive_kb_scope. Re-activating consumes an active max_projects slot, so it is rejected (422) when the tenant is at its cap. Rejects a kind: work project (422).",
    inputSchema: {
      type: "object",
      properties: {
        project_id: { type: "string", description: "UUID of the archived :kb scope to restore." },
      },
      required: ["project_id"],
    },
  },
  {
    name: "channel_post",
    description:
      "Post a message to a repo coordination channel (Epic 39 Repo Coordination Bus) on the agent key. A channel IS a project_id (a work project or a kb scope); posts are tenant-isolated by RLS. This is an agent-role COORDINATION surface, not chain-of-custody — posting to your own tenant's channel is not self-approval. host is auto-filled from the proxy's os.hostname() and session_id is auto-filled from the Claude Code session id (both proxy-supplied, informational only — do NOT pass them). Provide a key to upsert your per-session working-state slot (200) instead of appending a new post (201); omit it to append.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "UUID of the channel (a work project or kb scope) to post to.",
        },
        body: { type: "string", description: "The coordination message body." },
        key: {
          type: "string",
          description:
            "Optional per-session working-state slot key. When given, upserts the caller's slot for that key instead of appending a new post.",
        },
        refs: {
          type: "object",
          description:
            "Optional structured references map: { file, pr, branch, commit }.",
          properties: {
            file: { type: "string" },
            pr: { type: "string" },
            branch: { type: "string" },
            commit: { type: "string" },
          },
        },
      },
      required: ["project_id", "body"],
    },
  },
  {
    name: "channel_recent",
    description:
      "Read recent posts from a repo coordination channel (Epic 39 Repo Coordination Bus) on the agent key. A channel IS a project_id; RLS returns only your own tenant's channel, so this is an oracle-safe read. Use since (a full ISO8601 instant) to page forward from a known point and limit to cap results (default 25, max 100).",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "UUID of the channel (a work project or kb scope) to read.",
        },
        since: {
          type: "string",
          description:
            "Optional ISO8601 instant; return posts newer than this (date-only is ignored server-side).",
        },
        limit: {
          type: "integer",
          description: "Optional max posts to return (default 25, max 100).",
        },
      },
      required: ["project_id"],
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
      "Defaults to 20 per page; pass `limit` up to 500 to page larger. Use offset to paginate " +
      "(response includes total_count). Filter by epic_id or agent_status to reduce result size.",
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
          description: "Maximum number of stories to return (default 20, max 500).",
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
      "Paginated (page/page_size); advance `page` to enumerate all ready stories. " +
      "Response includes total_count.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "The UUID of the project.",
        },
        page: { type: "integer", description: "Page number (default 1)." },
        page_size: {
          type: "integer",
          description: "Stories per page (default 100, max 500).",
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
            model_name: { type: "string", description: "Model name (e.g. claude-sonnet-5)." },
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
      "Bulk mark multiple stories as complete (backfill-only for never-dispatched work). " +
      "ADMIN USE ONLY: backfill pre-existing completed work into pending stories that never entered the dispatch lifecycle. " +
      "For dispatched stories, use the normal report/review/verify flow. Each story entry needs a story_id, summary, and review_type. Uses the ORCH key.",
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
          description: "Name of the model used (e.g. claude-sonnet-5, gpt-4o).",
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
    description:
      "Get token usage records for a single story. Paginated (page/page_size); " +
      "advance `page` to enumerate all records.",
    inputSchema: {
      type: "object",
      properties: {
        story_id: {
          type: "string",
          description: "The UUID of the story.",
        },
        page: { type: "integer", description: "Page number (default 1)." },
        page_size: { type: "integer", description: "Records per page (default 20)." },
      },
      required: ["story_id"],
    },
  },
  {
    name: "get_cost_anomalies",
    description:
      "Get cost anomaly alerts — stories or agents that exceed expected token budgets. " +
      "Optionally filter by project. Paginated (page/page_size); advance `page` to " +
      "enumerate all anomalies.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "Optional: filter anomalies to a specific project UUID.",
        },
        page: { type: "integer", description: "Page number (default 1)." },
        page_size: { type: "integer", description: "Anomalies per page (default 20)." },
      },
      required: [],
    },
  },
  {
    name: "get_ingestion_anomalies",
    description:
      "Get ingestion-health anomalies — capture_silence (a source_type that was producing " +
      "articles has gone silent) and high_reject_rate (writes attempted but rejected at high " +
      "rate — 409 title_conflict / validation drops that persist no article row). Use to check " +
      "whether knowledge capture is still landing AND being accepted. Paginated (page/page_size); " +
      "advance `page` to enumerate all. Filter by source_type, anomaly_type, resolved status, or " +
      "include archived.",
    inputSchema: {
      type: "object",
      properties: {
        source_type: {
          type: "string",
          description: 'Optional: filter to one article source_type (e.g. "session_log").',
        },
        anomaly_type: {
          type: "string",
          // Keep in sync with Loopctl.Knowledge.IngestionAnomaly @anomaly_types (the
          // server-side Ecto.Enum + the ingestion_anomalies_anomaly_type_check DB CHECK).
          enum: ["capture_silence", "high_reject_rate"],
          description:
            'Optional: filter by anomaly type — "capture_silence" (writes stopped) or ' +
            '"high_reject_rate" (writes rejected at high rate).',
        },
        resolved: {
          type: "string",
          enum: ["false", "true", "all"],
          description:
            'Which anomalies to return: "false" = unresolved only (default), "true" = resolved only, "all" = both.',
        },
        include_archived: {
          type: "boolean",
          description: "Optional: include archived (retired-source) anomalies (default false).",
        },
        page: { type: "integer", description: "Page number (default 1)." },
        page_size: { type: "integer", description: "Anomalies per page (default 20, max 100)." },
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
      "rows. Returns { data: { tag: count }, meta: { distinct_count, truncated } }. " +
      "meta.distinct_count is the TRUE number of distinct tags (independent of limit); " +
      "meta.truncated flags when limit capped the rows. Each `count` is the number of distinct " +
      "articles carrying that tag. Pass tag_prefix to restrict to a tag family (e.g. 'book-') " +
      "so you get the DISTINCT count of that family (how many distinct books) plus per-member " +
      "totals — without dragging tens of thousands of rows through context. Honors the same " +
      "filters as knowledge_count (status, tags, match). Cost: unnests tags over the whole " +
      "filtered set; on large tenants narrow with tag_prefix/category/status/project_id.",
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
        limit: { type: "integer", description: "Optional: max distinct tags in the result (default all, max 1000; values above 1000 are rejected with 400)." },
      },
      required: [],
    },
  },
  {
    name: "knowledge_graph",
    description:
      "Traverse the published article-link graph outward from an article, up to `depth` hops " +
      "(1–3, default 1). BIDIRECTIONAL (follows links regardless of source/target direction) and " +
      "cycle-safe (no node twice). Returns { nodes: [{id,title,category,depth}], edges: " +
      "[{source_article_id,target_article_id,relationship_type}], truncated, node_count }. Bounded " +
      "to 100 nodes / 500 edges (truncated:true when hit). Use to explore how a piece of knowledge " +
      "connects (relates_to/derived_from/contradicts/supersedes) beyond the 1-hop links in " +
      "knowledge_context.",
    inputSchema: {
      type: "object",
      properties: {
        article_id: {
          type: "string",
          format: "uuid",
          description: "Starting article UUID (required).",
        },
        depth: {
          type: "integer",
          minimum: 1,
          maximum: 3,
          description: "Hops to traverse (1–3, default 1). Out of range → 400.",
        },
        project_id: { type: "string", format: "uuid", description: "Optional: project UUID." },
      },
      required: ["article_id"],
    },
  },
  {
    name: "knowledge_suggest_links",
    description:
      "Suggest ranked typed-link CANDIDATES for an article by embedding similarity — " +
      "READ-ONLY, creates nothing. Excludes the article itself and any already-linked " +
      "article (either direction, any relationship type); only embedded published articles. " +
      "Returns { data: [{id, title, category, similarity_score}] } highest-similarity first. " +
      "Review them and create the one you want as a TYPED link (relates_to/derived_from/" +
      "contradicts/supersedes) — unlike the auto-linker which only makes ambient relates_to. " +
      "Optional: threshold (cosine floor 0–1, default 0.5), limit (default 5).",
    inputSchema: {
      type: "object",
      properties: {
        article_id: {
          type: "string",
          format: "uuid",
          description: "The article to suggest links for (required).",
        },
        limit: { type: "integer", description: "Max candidates (default 5)." },
        threshold: {
          type: "number",
          minimum: 0,
          maximum: 1,
          description: "Cosine similarity floor (default 0.5).",
        },
      },
      required: ["article_id"],
    },
  },
  {
    name: "knowledge_distant_pairs",
    description:
      "Find distant-but-bridgeable article pairs in the optimal-novelty embedding band " +
      "(cosine distance min..max, default 0.3–0.7) — the creative sweet spot (neither banal " +
      "nor nonsense). Returns { data: [{a, b, distance}], meta:{count, has_more, total_count} }. " +
      "Paginate via meta.has_more (a limit+1 look-ahead) — NOT total_count, which is DEPRECATED " +
      "and always null here: unlike sibling offset/limit tools, an exact total is an " +
      "O(candidates²) cost (the pair set is a column-to-column self-join), so it was removed for " +
      "latency (loopctl #202/#203). With bridge_path:true, only pairs also connected in the link " +
      "graph (≤2 hops) are returned — that branch samples a smaller candidate slice, so it may " +
      "return fewer pairs. Samples up to 1000 embedded published articles (500 for bridge_path). " +
      "For computational-creativity ideation (remote-associates generator).",
    inputSchema: {
      type: "object",
      properties: {
        min_distance: { type: "number", description: "Lower cosine-distance bound (default 0.3)." },
        max_distance: { type: "number", description: "Upper cosine-distance bound (default 0.7)." },
        bridge_path: { type: "boolean", description: "Require a ≤2-hop graph path (default false)." },
        limit: { type: "integer", description: "Max pairs (default 20, max 100)." },
        offset: { type: "integer", description: "Pairs to skip." },
      },
      required: [],
    },
  },
  {
    name: "knowledge_novelty",
    description:
      "Score the NOVELTY of ideas: each idea's text is embedded and compared to the nearest " +
      "prior proposal, returning novelty_score = cosine distance (0 = identical to existing " +
      "work, higher = more novel, up to 2.0; null when the idea text is blank, no priors " +
      "exist, or embedding fails). Priors default to published articles tagged 'proposal' " +
      "(override with prior_tag). Provide the ideas as EITHER `texts` (a list of strings) " +
      "OR `ideas` (a list of strings or objects {text|title/spark/thesis,...}); all forms " +
      "are accepted. " +
      "Returns { data: [{...idea, novelty_score}], meta: { prior_count } }. Use to rerank " +
      "generated ideas by novelty × value and avoid repeating prior work.",
    inputSchema: {
      type: "object",
      properties: {
        ideas: {
          type: "array",
          description:
            "Ideas to score (≤50). Each is a string, or an object whose embed text is " +
            "`text` (else title/spark/thesis are joined).",
          items: { type: ["string", "object"] },
        },
        texts: {
          type: "array",
          description: "Alternative to `ideas`: a list of idea strings (the #152 AC shape).",
          items: { type: "string" },
        },
        prior_tag: {
          type: "string",
          description: "Tag identifying prior proposals to compare against (default 'proposal').",
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_random_walk",
    description:
      "Random walk through the link graph from a starting article (up to `length` published " +
      "nodes, no cycles, stops at a dead end). Surfaces unexpected connections for creative " +
      "incubation. Returns { data: [{id,title,category}], meta:{count} } in walk order.",
    inputSchema: {
      type: "object",
      properties: {
        start_id: { type: "string", format: "uuid", description: "Starting article UUID (required)." },
        length: { type: "integer", description: "Walk steps (default 4, max 25)." },
      },
      required: ["start_id"],
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
      "Pass story_id when working on a loopctl story so reads attribute correctly. " +
      "When you knowledge_get a result and it carries `potential_conflicts`, resolve it if it's " +
      "material to your task (see knowledge_get / the conflict-resolution wiki playbook). " +
      "If semantic ranking is unavailable the search transparently degrades to keyword-only " +
      "(meta.fallback: true, meta.search_mode: 'keyword_only') and now reports meta.fallback_reason " +
      "— a stable tag naming WHY (e.g. no_embedding_key, embedding_circuit_open, " +
      "embedding_provider_error_<status>, embedding_timeout). When the reason is a MISSING " +
      "embedding key (no_embedding_key), the result leads with an ACTION REQUIRED notice + " +
      "meta.remediation telling you to provision it with set_llm_config (BYO — do it once).",
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
    name: "knowledge_hybrid_search",
    description:
      "Resolve a topic to a SINGLE best answer WITH provenance — the hybrid " +
      "retrieval entrypoint. Runs the combined keyword+semantic search over the full " +
      "ranked pool, then decides whether a governed CURATED source actually answers. " +
      "The verdict is meta.provenance: 'curated' means a curated, canonical article " +
      "answers — TRUST IT (it is guaranteed first in the results and meta.curated_article_id " +
      "points at it); 'retrieved' means no curated source cleared the bar, so the answer " +
      "is the best semantic/keyword match (a fuzzy fallback — verify before relying on it, " +
      "meta.curated_article_id is null). meta.confidence is the winning candidate's absolute " +
      "score for its provenance class. Prefer this over knowledge_search when you want ONE " +
      "trustworthy answer plus its provenance rather than a ranked list to triage yourself; " +
      "use knowledge_search when you want to browse/enumerate matches. Additive — existing " +
      "knowledge tools are unchanged. If semantic ranking is unavailable it degrades to " +
      "keyword-only (meta.fallback/fallback_reason), same as knowledge_search.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "The topic/question to resolve (max 500 characters). Required.",
        },
        project_id: {
          type: "string",
          format: "uuid",
          description: "Optional: scope to a project UUID.",
        },
        category: {
          type: "string",
          description: "Optional: filter by category.",
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
        limit: {
          type: "integer",
          description: "Optional: max results to return (default 10).",
        },
        offset: {
          type: "integer",
          description: "Optional: results to skip for pagination (default 0).",
        },
      },
      required: ["query"],
    },
  },
  {
    name: "knowledge_progressive_index",
    description:
      "Progressive disclosure — get a CHEAP, capped index of what's relevant to a topic " +
      "(compact stubs: id/title/category/summary, NO bodies), then open only what you need " +
      "with knowledge_progressive_drill. Curated sources are preferred and hub-linked " +
      "neighbors are enriched in; results are capped at a configured top-K (meta.truncated " +
      "is true when the candidate pool exceeded it). Use this to survey a topic without " +
      "flooding your context with full article bodies — it's the index half of the hybrid " +
      "interface. Follow up on a stub's id with knowledge_progressive_drill to read the body.",
    inputSchema: {
      type: "object",
      properties: {
        topic: {
          type: "string",
          description: "The topic to index (max 500 characters). Required.",
        },
        category: {
          type: "string",
          description: "Optional: filter by category.",
        },
        limit: {
          type: "integer",
          description: "Optional: top-K override (clamped to the configured cap).",
        },
      },
      required: ["topic"],
    },
  },
  {
    name: "knowledge_progressive_drill",
    description:
      "Drill into one stub from knowledge_progressive_index — returns the FULL article " +
      "body for the given id, scope-enforced. Resolves both tenant-owned articles and " +
      "published system canonicals (the same set the index surfaces). This is the drill " +
      "half of progressive disclosure: index cheaply, then open only the article(s) you " +
      "need. (knowledge_get works for tenant articles too; use this to also reach the " +
      "system canonicals the progressive index can surface.)",
    inputSchema: {
      type: "object",
      properties: {
        article_id: {
          type: "string",
          format: "uuid",
          description: "The UUID of the article to open (from a progressive index stub).",
        },
      },
      required: ["article_id"],
    },
  },
  {
    name: "knowledge_get",
    description:
      "Get full article content by ID. Use after search to read an article in detail. " +
      "Pass story_id when working on a loopctl story so reads attribute correctly. " +
      "If the response carries a non-empty `potential_conflicts` array AND the conflict is " +
      "material to your current task, act on it: read the peer, judge redundant/complementary/" +
      "contradictory against the live system, and knowledge_resolve_conflict (dismiss a false " +
      "positive, supersede when one clearly wins, merge when both should combine). If you can't " +
      "tell which is right, leave it. See the 'Resolving knowledge conflicts' wiki playbook.",
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
      "Pass story_id when working on a loopctl story so reads attribute correctly. For agent " +
      "memory, scope to a memory_type/agent/conversation via the memory_types/agents/" +
      "conversation_id filters (articles whose metadata carries those keys). NOTE (#163): for " +
      "an agent key, another agent's private/owner memories are never returned (results AND " +
      "linked refs) regardless of the agents= filter — visibility is enforced, not advisory. " +
      "If semantic ranking is unavailable this degrades to keyword-only (meta.fallback: true) and " +
      "now reports meta.fallback_reason — a stable tag naming WHY (e.g. no_embedding_key, " +
      "embedding_circuit_open, embedding_provider_error_<status>, embedding_timeout).",
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
        memory_types: {
          type: "string",
          description:
            "Optional agent-memory scope: comma-separated memory_types (OR) — " +
            "observation|finding|summary|decision|question|task.",
        },
        agents: {
          type: "string",
          description: "Optional agent-memory scope: comma-separated agent_ids (OR).",
        },
        conversation_id: {
          type: "string",
          description: "Optional agent-memory scope: exact conversation_id.",
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
      "NOVELTY GATE (default ON): the server semantically dedups your proposal against the published " +
      "corpus and returns a `gate.verdict` — `duplicate` means a near-identical article already exists, " +
      "so NOTHING was created (HTTP 200, `deduplicated: true`); read/update the article at `data.id` " +
      "instead (its `gate.similarity` ~1.0). `gated_to_draft` means high overlap, so the article was " +
      "created as a DRAFT (not published) with the near-neighbors in metadata.proposal_novelty for you " +
      "to merge or publish. `created` means it was novel and went through normally. Pass force: true to " +
      "bypass the gate when you intentionally want an article near an existing one. " +
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
        force: {
          type: "boolean",
          description:
            "Optional: bypass the novelty gate (default false). When true, the server skips " +
            "semantic dedup and creates on the requested path even if a near-duplicate exists. " +
            "Use only when you've already checked and intend an article close to an existing one.",
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
        metadata: {
          type: "object",
          description:
            "Optional: extensible JSONB. Set the agent-memory keys to file this article as a " +
            "scoped agent memory: `memory_type` (observation/finding/summary/decision/question/" +
            "task) and `visibility` (shared | private | owner). TRUST MODEL (#163): for an " +
            "agent key, `metadata.agent_id` is stamped server-side from your verified key " +
            "identity — do NOT set it (any value you pass is overridden); `private`/`owner` " +
            "memories are then readable only by you (other agents get 404/exclusion across all " +
            "knowledge reads), while `shared` (the default) is visible tenant-wide. An agent " +
            "key with no agent identity gets 403 agent_identity_required when writing memory " +
            "metadata. Higher roles may attribute on behalf of others.",
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
  {
    name: "knowledge_update",
    description:
      "Edit an EXISTING knowledge article IN PLACE, preserving its ID. Use this to fold a " +
      "new fact into a canonical article, tidy a hub, retag, or reclassify — WITHOUT " +
      "creating a new row and churning the article ID (IDs are load-bearing: cited in " +
      "project CLAUDE.mds and cross-links). Send only the fields you want to change; every " +
      "field is optional except article_id. `tags` REPLACES the whole array (send the full " +
      "desired set, not a delta). A changed body/tags re-triggers embedding + auto-linking. " +
      "Agent role — this is KB-content curation (reversible + audited). Visibility-scoped: " +
      "you can only edit an article you can see, so another agent's private/owner memory " +
      "returns 404. `tenant_id` is never accepted. Returns the full updated article. To " +
      "instead retire/replace an article, use knowledge_archive or knowledge_resolve_conflict.",
    inputSchema: {
      type: "object",
      properties: {
        article_id: {
          type: "string",
          description: "The UUID of the article to edit (preserved across the update).",
        },
        title: {
          type: "string",
          description: "Optional: new title.",
        },
        body: {
          type: "string",
          description: "Optional: new body (Markdown). Re-triggers embedding + linking.",
        },
        category: {
          type: "string",
          description: "Optional: new category.",
        },
        tags: {
          type: "array",
          items: { type: "string" },
          description: "Optional: REPLACES the whole tags array (send the full desired set).",
        },
        metadata: {
          type: "object",
          description:
            "Optional: extensible JSONB (merged/replaced wholesale). For an agent key, an " +
            "agent-memory `agent_id` is stamped from your verified key identity — you cannot " +
            "re-attribute a memory to another agent.",
        },
      },
      required: ["article_id"],
    },
  },

  // Agent Memory Tools (US-28.4)
  {
    name: "memory_remember",
    description:
      "Write to YOUR OWN scoped, private, accumulated working memory — running notes, " +
      "in-flight task state, decisions you made this session — NOT the shared knowledge " +
      "wiki. Use memory_* for private per-scope working state across sessions; use " +
      "knowledge_* for curated, shared knowledge articles other agents should see. Scope " +
      "(tenant_id/subject_id) is resolved server-side from your API key — never pass or " +
      "expect a tenant_id/subject_id here; there is no way to write into another scope. " +
      "`tier` selects the substrate: `long_term` (default; requires `text`, embedded " +
      "asynchronously and later recalled by semantic similarity via memory_recall) or " +
      "`session` (short-term; requires `session_id`, `content`, `expires_at` — pruned " +
      "after expiry, not semantically recalled). Returns 201 with the stored memory.",
    inputSchema: {
      type: "object",
      properties: {
        tier: {
          type: "string",
          enum: ["long_term", "session"],
          description: "Memory substrate. Defaults to long_term.",
        },
        text: {
          type: "string",
          description: "Long-term memory content (required when tier=long_term).",
        },
        confidence: {
          type: "number",
          description: "Optional: confidence score (0.0-1.0) for a long-term memory.",
        },
        tags: {
          type: "array",
          items: { type: "string" },
          description: "Optional: tags for a long-term memory.",
        },
        source_session_id: {
          type: "string",
          description: "Optional: the session this long-term memory was distilled from.",
        },
        session_id: {
          type: "string",
          description: "Session identifier (required when tier=session).",
        },
        role: {
          type: "string",
          enum: ["user", "assistant", "system", "fact"],
          description: "Optional: speaker role for a session-tier turn.",
        },
        content: {
          type: "string",
          description: "Session turn content (required when tier=session).",
        },
        expires_at: {
          type: "string",
          format: "date-time",
          description: "Prune deadline (required when tier=session).",
        },
        metadata: {
          type: "object",
          description: "Optional: arbitrary structured metadata to attach to the memory.",
        },
      },
      required: [],
    },
  },
  {
    name: "memory_recall",
    description:
      "Semantically recall YOUR OWN long-term memories most similar to `query` — private, " +
      "scoped working state, NOT the shared knowledge wiki. Use memory_* for your scoped, " +
      "private, accumulated working state across sessions; use knowledge_* for curated, " +
      "shared knowledge articles. Scope is resolved server-side from your API key. When " +
      "embedding generation is unavailable the response degrades to a recent-first text " +
      "match with `meta.fallback: true` and a stable `meta.reason` (score is null on that " +
      "path) — check meta.fallback before treating a short/empty result as a genuinely " +
      "empty scope. `meta.total_count` and `meta.underfilled` are also returned so you can " +
      "distinguish a short page from a hard cap.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Text to embed / match against.",
        },
        limit: {
          type: "integer",
          description: "Optional: max results, clamped to the vector-search max (no silent hard cap).",
        },
        include_superseded: {
          type: "boolean",
          description: "Optional: include superseded memories (default false).",
        },
      },
      required: ["query"],
    },
  },
  {
    name: "recall_context",
    description:
      "MERGED recall in ONE round-trip: the re-ranked global ∪ active-project union of " +
      "your long-term MEMORY (private working state) AND the shared KNOWLEDGE wiki for " +
      "`query` — instead of calling memory_recall and knowledge_context/knowledge_search " +
      "separately and merging by hand (#411 Gap 2). Both sides merge global with the " +
      "active project: pass project_id to include that project's rows alongside global " +
      "ones on BOTH sides (another project's rows are excluded); omit it for global-only. " +
      "project_id is a PARTITION key, NOT isolation — scope (tenant/subject) is resolved " +
      "server-side from your key. Returns `data` (merged, each item tagged source: " +
      "memory|knowledge, sorted by a heuristically-comparable score DESC) PLUS the " +
      "untouched per-source `memory` and `knowledge` envelopes so you can re-rank. " +
      "Cross-source scores are heuristic, not calibrated. If the knowledge search " +
      "degrades (embedding unavailable) or errors, the memory side is still returned and " +
      "meta.degraded is true — never a hard failure.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Text to embed / match against on BOTH the memory and knowledge sides.",
        },
        project_id: {
          type: "string",
          format: "uuid",
          description:
            "Optional: partition scope. Present → both sides return global ∪ that project; " +
            "omit → global-only.",
        },
        limit: {
          type: "integer",
          description:
            "Optional: overall merged page size, clamped to [1, 50] (default 10).",
        },
      },
      required: ["query"],
    },
  },
  {
    name: "memory_list",
    description:
      "List YOUR OWN long-term memories, newest first — private, scoped working state, " +
      "NOT the shared knowledge wiki. Use memory_* for your scoped, private, accumulated " +
      "working state across sessions; use knowledge_* for curated, shared knowledge " +
      "articles. Scope is resolved server-side from your API key. Paginated with " +
      "`meta.total_count/limit/offset` (the true scoped count, never silently capped by " +
      "limit) so you can distinguish an empty scope from a short page.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "integer",
          description: "Optional: page size (default 50, max 200).",
        },
        offset: {
          type: "integer",
          description: "Optional: records to skip (default 0).",
        },
        include_superseded: {
          type: "boolean",
          description: "Optional: include superseded memories (default false).",
        },
        all_subjects: {
          type: "boolean",
          description:
            "Optional, superadmin only: list all subjects' memories in the tenant. Ignored " +
            "(falls back to your own subject) for non-superadmin keys.",
        },
      },
      required: [],
    },
  },
  {
    name: "memory_forget",
    description:
      "Delete one of YOUR OWN long-term memories by id — private, scoped working state, " +
      "NOT the shared knowledge wiki. Use memory_* for your scoped, private, accumulated " +
      "working state; use knowledge_* for curated, shared knowledge articles (delete those " +
      "with knowledge_delete). Scope is resolved server-side from your API key: a foreign-" +
      "subject, foreign-tenant, or unknown id returns 404 (no existence leak) rather than " +
      "revealing whether it exists in another scope.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          format: "uuid",
          description: "The UUID of the memory to forget.",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "memory_promote",
    description:
      "Call at session end to compile this session's short-term memory into durable long-term memory" +
      " — private, scoped working state, NOT the shared knowledge wiki. Unlike " +
      "memory_remember, which writes a single explicit fact, this compiles the WHOLE session's " +
      "session-tier memory in one shot — fire it once at session end, not per turn. Scope " +
      "(tenant_id/subject_id) is resolved server-side from your API key: you can only promote " +
      "your OWN sessions. Returns 202 Accepted with `{job_id, session_id, status: \"enqueued\"}` " +
      "— promotion runs asynchronously via a background worker, so the resulting long-term " +
      "memory becomes recallable via memory_recall only after that worker drains, not " +
      "immediately.",
    inputSchema: {
      type: "object",
      properties: {
        session_id: {
          type: "string",
          description: "The session whose short-term memory to compile into long-term memory.",
        },
      },
      required: ["session_id"],
    },
  },
  {
    name: "memory_graduate",
    description:
      "Graduate ONE of your long-term memories into a durable Knowledge Wiki article — the " +
      "explicit, on-demand version of the hourly graduation sweep. Use when a private memory " +
      "has proven valuable enough to become durable, curated knowledge. IMPORTANT: the " +
      "graduated article stays OWNER-VISIBLE (metadata.visibility=owner, keyed to your " +
      "subject) — discoverable by YOU, NOT peer-readable; graduation does NOT share a memory " +
      "with teammates, and re_scope only widens project scope, not visibility. Scope " +
      "(tenant_id/subject_id) is resolved server-side from your API key: you can only " +
      "graduate your OWN memory; a foreign/unknown memory_id returns 404 (no cross-subject " +
      "leak). By default the article inherits the memory's project scope; pass " +
      're_scope: "global" to promote a PROJECT memory to a tenant-wide (global) article — ' +
      "only valid on the memory's FIRST graduation (re_scope: global on an already-graduated " +
      "PROJECT memory returns 409 already_graduated; on an already-graduated GLOBAL memory it " +
      "is an idempotent no-op → 200). The article is DEDUPED by the novelty gate: the " +
      'response `data.verdict` is "created" (novel → published) or "gated_to_draft" ' +
      '(near-duplicate → review draft) with a new article, or "duplicate"/"deduplicated" ' +
      "(content already represented → the canonical article, nothing created). Returns 503 " +
      "gate_unavailable if the embedding backend is down — retry later.",
    inputSchema: {
      type: "object",
      properties: {
        memory_id: {
          type: "string",
          description: "UUID of your own long-term memory to graduate into a knowledge article.",
        },
        re_scope: {
          type: "string",
          enum: ["inherit", "global"],
          description:
            'Article scope. "inherit" (default) keeps the memory\'s project scope; ' +
            '"global" promotes a PROJECT memory to a tenant-wide (global) article ' +
            "(only on its first graduation).",
        },
      },
      required: ["memory_id"],
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
    name: "knowledge_bulk_unpublish",
    description:
      "Unpublish (published → draft) articles in bulk, partial-success style — the mirror " +
      "of knowledge_bulk_publish, for cleanup passes. REQUIRES LOOPCTL_USER_KEY (user role). " +
      "Every currently-published id is reverted to draft; each other id gets a per-id outcome: " +
      "unpublished, skipped (already draft — idempotent — or archived/superseded), not_found, " +
      "or errored. Duplicate ids de-duplicated; no 100-id cap (auto-chunked server-side, " +
      "bounded to 5000/call). meta.count = number actually unpublished; meta.counts has the " +
      "full breakdown; meta.results is the per-id list in request order. Safe to retry — " +
      "already-draft ids are skipped, not errored. Articles are NOT deleted (re-publish with " +
      "knowledge_bulk_publish); to archive/soft-delete use knowledge_bulk_delete.",
    inputSchema: {
      type: "object",
      properties: {
        article_ids: {
          type: "array",
          items: { type: "string" },
          description:
            "Article UUIDs to unpublish. Any length (auto-chunked); duplicates ignored.",
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
      "and the index but the row is retained for audit/history (reversible — re-publish " +
      "or edit it back). Works for drafts and published articles. Agent role — KB-content " +
      "curation. Visibility-scoped: you can only archive an article you can see, so " +
      "another agent's private/owner memory returns 404.",
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
      "is retained for audit; there is no hard delete (that is knowledge_bulk_delete " +
      "hard:true, which stays user-gated). Agent role — KB-content curation, reversible + " +
      "audited, visibility-scoped (another agent's private/owner memory 404s).",
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
      "Bulk archive (default, reversible) or IRREVERSIBLE hard-delete of articles by selector. " +
      "REQUIRES LOOPCTL_USER_KEY (user role — orchestrator is NOT sufficient). Provide EXACTLY ONE " +
      "selector: article_ids (explicit list), source_type + source_id (every active article from " +
      "that source), or tag + confirm:true (every active article carrying the tag — high blast " +
      "radius, so confirm:true is required). " +
      "DEFAULT (soft archive): rows move to archived, never dropped; set-based + idempotent; " +
      "meta.count = archived, meta.counts/meta.results give the breakdown. " +
      "DRY-RUN: dry_run:true mutates NOTHING and returns meta.would_affect (and, for hard, a " +
      "single-use meta.token / for oversized selectors a meta.confirm_hash). " +
      "HARD DELETE (irreversible): first dry_run with hard:true to get a token, then call again " +
      "with hard:true + that token to FK-correctly delete the FROZEN id-set (links removed first, " +
      "access events cascade). The token is single-use and TTL-bounded. Bounded to 5000 per call.",
    inputSchema: {
      type: "object",
      properties: {
        article_ids: {
          type: "array",
          items: { type: "string" },
          description: "Explicit article UUIDs (selector 1).",
        },
        source_type: {
          type: "string",
          description: "With source_id: every active article from this source (selector 2).",
        },
        source_id: {
          type: "string",
          description: "With source_type: the source entity UUID (selector 2).",
        },
        tag: {
          type: "string",
          description:
            "Every active article carrying this tag (selector 3). Requires confirm:true.",
        },
        confirm: {
          type: "boolean",
          description: "Required (true) when selecting by tag — guards the high blast radius.",
        },
        dry_run: {
          type: "boolean",
          description:
            "Preview only — mutate nothing. Returns meta.would_affect; with hard:true also a " +
            "single-use meta.token (or meta.confirm_hash for oversized selectors).",
        },
        hard: {
          type: "boolean",
          description:
            "IRREVERSIBLE hard delete (vs default reversible archive). Run dry_run first to get a " +
            "token, then pass hard:true + token.",
        },
        token: {
          type: "string",
          description:
            "The single-use frozen-set token from a `dry_run:true, hard:true` preview. Required " +
            "for the hard delete.",
        },
        confirm_hash: {
          type: "string",
          description:
            "For an oversized hard-delete selector (no token): the meta.confirm_hash from the " +
            "dry-run, echoed back to re-confirm the id-set hasn't drifted.",
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
      "(limit honored up to 1000; a limit above the max is clamped to the maximum, " +
      "never rejected, so pagination stays complete).",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "integer",
          description:
            "Max drafts per page (default 20, max 1000). A limit above the max is " +
            "clamped to the maximum — never rejected — so offset pagination stays complete.",
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
    name: "knowledge_conflicts",
    description:
      "List potential-conflict article pairs — published articles flagged 'too similar " +
      "to comfortably coexist' by the auto-linker / nightly lint sweep, highest-overlap " +
      "first. The KB only FLAGS the pair (via a mechanical similarity threshold); it does " +
      "NOT decide whether it's a redundancy to merge or a real contradiction — that's your " +
      "call, with the live context. Each entry has the two articles (id/title/status/" +
      "category) and their similarity. Read both, then merge (supersede one, knowledge_create " +
      "the merged article, or PATCH) or, if they genuinely disagree, reconcile. Paginated " +
      "with total_count in meta. Agent role.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "integer",
          description:
            "Max pairs per page (default 50, max 1000). A limit above the max is clamped " +
            "to the maximum — never rejected — so offset pagination stays complete.",
          default: 50,
          minimum: 1,
          maximum: 1000,
        },
        offset: {
          type: "integer",
          description: "Pagination offset. Default 0.",
          default: 0,
          minimum: 0,
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_resolve_conflict",
    description:
      "Record YOUR verdict on a potential-conflict pair (from knowledge_conflicts or an " +
      "article's potential_conflicts). You have the live context the KB lacks — it never " +
      "re-judges, it acts on what you record. Dispositions: 'dismiss' (a false positive — " +
      "the two don't actually conflict; drops out of the queue immediately); 'supersede' " +
      "(one article wins — pass authoritative_article_id, the winner; the nightly executor " +
      "creates a supersedes link and retires the loser, but ONLY at confidence:\"high\" — " +
      "reversible and audited); 'merge' (at confidence:\"high\" the nightly executor has an LLM " +
      "synthesize the two into ONE new DRAFT — both sources preserved, never auto-published, " +
      "for you/a human to review and publish). Non-destructive " +
      "at agent role — you record intent; the privileged nightly job executes it. " +
      "Last-write-wins per pair, so re-recording with fresher ground truth overrides. " +
      "Resolve only conflicts material to your current task; adjudicate against the actual " +
      "system, and if you can't tell which is right, leave it (or record low confidence) " +
      "rather than guessing.",
    inputSchema: {
      type: "object",
      properties: {
        source_article_id: {
          type: "string",
          description: "One article of the conflict pair (UUID). Order does not matter.",
        },
        target_article_id: {
          type: "string",
          description: "The other article of the conflict pair (UUID).",
        },
        disposition: {
          type: "string",
          enum: ["dismiss", "supersede", "merge"],
          description:
            "dismiss = false positive; supersede = one wins (set authoritative_article_id); " +
            "merge = combine both into one new DRAFT (LLM-synthesized by the nightly executor " +
            "at high confidence; sources preserved, never auto-published).",
        },
        authoritative_article_id: {
          type: "string",
          description:
            "For supersede/merge: the WINNING article (must be one of the pair). The other " +
            "is the loser to retire/merge into the winner.",
        },
        classification: {
          type: "string",
          enum: ["redundant", "complementary", "contradictory"],
          description:
            "Your judgment of the relationship: redundant (same claim), complementary (same " +
            "topic, different facets — usually a dismiss), or contradictory (can't both be true).",
        },
        evidence: {
          type: "string",
          description:
            "Why you're sure — ideally a ground-truth reference (commit, file:line, URL, or the " +
            "observed behavior). Recorded for audit and for a human reviewing low-confidence calls.",
        },
        confidence: {
          type: "string",
          enum: ["high", "medium", "low"],
          description:
            "high, medium, or low. supersede auto-executes only at 'high'; lower confidence is " +
            "recorded but left for review. Default medium.",
        },
      },
      required: ["source_article_id", "target_article_id", "disposition"],
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
      "Export all knowledge articles as an OKF v0.1 bundle — gzipped tar archive, unbounded, bounded-memory streaming, " +
      "fail-closed (no partial bundles). Because binary cannot be returned as MCP content, this tool returns a curl command. " +
      "Optional: ?format=json for buffered in-memory JSON (capped at export_max_buffered_export_articles, 413 over cap).",
    inputSchema: {
      type: "object",
      properties: {
        project_id: {
          type: "string",
          description: "Optional: scope export to a specific project UUID.",
        },
        format: {
          type: "string",
          enum: ["tar.gz", "json"],
          description: "Optional: tar.gz (default, unbounded streaming) or json (buffered, capped).",
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
      "publish them on extraction. Requires orchestrator role. BYO: extraction runs on the " +
      "tenant's OWN Anthropic key — a keyless tenant gets a 422 (code no_api_key) and the " +
      "result leads with an ACTION REQUIRED notice telling you to provision it once via " +
      "set_llm_config.",
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
      "List content ingestion jobs for the current tenant, newest first. " +
      "Paginated (limit/offset over the full history; advance `offset` by `meta.limit` " +
      "to enumerate to completeness). Optional `since_days` narrows to a recent window. " +
      "Requires orchestrator role.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "integer", description: "Jobs per page (default 20)." },
        offset: { type: "integer", description: "Rows to skip (default 0)." },
        since_days: {
          type: "integer",
          description: "Optional: only jobs from the last N days (default: all history).",
        },
      },
      required: [],
    },
  },

  // Per-tenant BYO LLM config + usage (Epic 28 residual, #179)
  {
    name: "llm_config",
    description:
      "CHECK your BYO LLM onboarding status. Returns this tenant's per-operation model " +
      "choices and whether each key is configured — `has_api_key` (Anthropic, powers " +
      "ingest) and `has_embedding_key` (OpenAI embedding, powers semantic search) — plus " +
      "masked last-4 hints. NEVER returns a key itself. Call this BEFORE ingest/search to " +
      "confirm setup, or after set_llm_config to verify it took. Uses your user-role key " +
      "(LOOPCTL_USER_KEY, obtained at signup); managing tenant secrets is user-only, so an " +
      "agent/orchestrator key is rejected.",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "set_llm_config",
    description:
      "FIRST-TIME SETUP — do this ONCE, right after signup, to bring the wiki online. " +
      "Provision your OWN Anthropic + OpenAI embedding keys so knowledge ingest AND " +
      "semantic search work. loopctl is strictly BYO: it fronts NO LLM cost — your keys " +
      "bill you directly and are stored ENCRYPTED, never returned. WHY it's required: with " +
      "no `api_key`, knowledge_ingest returns 422 (code no_api_key); with no " +
      "`embedding_api_key`, knowledge_search silently degrades to keyword-only " +
      "(meta.fallback_reason: no_embedding_key) — both responses carry a `remediation` " +
      "pointing back to THIS tool. WHICH key powers WHAT: `api_key` (Anthropic) → ingest " +
      "extraction / classification / merge synthesis; `embedding_api_key` " +
      "(OpenAI-compatible) → article embeddings + semantic ranking. All params are optional " +
      "and partial-merge — omitting a key leaves the existing one untouched, so you can set " +
      "or rotate one at a time. The per-operation model overrides " +
      "(extraction_model / classification_model / merge_model / embedding_model) are " +
      "free-form (any model the key permits) and default server-side when omitted. Typical " +
      'onboarding call: set_llm_config({api_key: "sk-ant-...", embedding_api_key: "sk-..."}). ' +
      "Verify anytime with llm_config (has_api_key / has_embedding_key). REQUIRES your " +
      "user-role key LOOPCTL_USER_KEY (minted by the human-anchored signup ceremony); if it " +
      "is unset the tool fails fast telling you to set it.",
    inputSchema: {
      type: "object",
      properties: {
        api_key: {
          type: "string",
          description:
            "Anthropic API key — powers knowledge ingest (extraction/classification/merge). " +
            "Write-only; stored encrypted, never returned.",
        },
        extraction_model: {
          type: "string",
          description: "Model id for knowledge extraction (null → server default).",
        },
        classification_model: {
          type: "string",
          description: "Model id for category classification (null → server default).",
        },
        merge_model: {
          type: "string",
          description: "Model id for article merge synthesis (null → server default).",
        },
        embedding_api_key: {
          type: "string",
          description:
            "OpenAI-compatible embedding API key — powers article embeddings + semantic " +
            "search. Write-only; stored encrypted, never returned. Without it, articles are " +
            "not vector-searchable and search degrades to keyword-only.",
        },
        embedding_model: {
          type: "string",
          description:
            "Embedding model id (null → server default text-embedding-3-small).",
        },
      },
      required: [],
    },
  },
  {
    name: "knowledge_llm_usage",
    description:
      "Per-tenant LLM token-usage summary, grouped by operation + model + source_type + " +
      "day over an optional date range, newest day first, with offset/limit pagination " +
      "over meta.total_count. When `from` is omitted it defaults to a 90-day lookback; the " +
      "EFFECTIVE window is echoed in meta.from/meta.to so you can detect that older usage " +
      "was excluded (pass an explicit `from` to widen it). Record-only — there is no budget " +
      "enforcement. Requires orchestrator role.",
    inputSchema: {
      type: "object",
      properties: {
        from: {
          type: "string",
          description: "Optional ISO 8601 lower bound (inclusive) on occurred_at.",
        },
        to: {
          type: "string",
          description: "Optional ISO 8601 upper bound (inclusive) on occurred_at.",
        },
        limit: {
          type: "integer",
          description: "Rows per page (default 50, clamped to 200).",
        },
        offset: { type: "integer", description: "Rows to skip (default 0)." },
      },
      required: [],
    },
  },

  // Knowledge Analytics Tools (orchestrator key)
  {
    name: "knowledge_curation_log",
    description:
      "The concise, human-readable log of KB CURATION adjustments — novelty-gate decisions " +
      "(gate_duplicate/gate_draft) and conflict resolutions (supersede/merge/dismiss) — for " +
      "analyzing the agents'-KB rollout, distinct from the verbose audit log. Each entry is a " +
      "one-liner: {at, kind, summary, refs, actor, confidence}. RECORDED ONLY while the tenant " +
      "has the toggle on: settings.kb_curation_log (flip via the admin tenant API, " +
      "PATCH /api/v1/admin/tenants/:id with settings:{kb_curation_log:true}). Off by default = " +
      "no rows. Filter by kind and since (ISO8601). Most recent first. Requires orchestrator role.",
    inputSchema: {
      type: "object",
      properties: {
        kind: {
          type: "string",
          description:
            "Optional: filter by kind (gate_duplicate | gate_draft | supersede | merge | dismiss).",
        },
        since: {
          type: "string",
          description: "Optional: ISO8601 date or datetime lower bound (inclusive).",
        },
        limit: {
          type: "integer",
          description: "Events per page (default 50, max 500). Clamped, never rejected.",
          minimum: 1,
          maximum: 500,
        },
        offset: { type: "integer", description: "Events to skip. Default 0.", minimum: 0 },
      },
      required: [],
    },
  },
  {
    name: "knowledge_retrieval_metrics",
    description:
      "Return the daily retrieval-PRECISION time series (agents' KB #3): for each day, the " +
      "share of search results the agent then opened (search → get/context within a window). " +
      "A proxy for whether retrieval is improving — watch it trend up as the corpus is " +
      "de-duplicated, better navigated (MOCs), and conflict-resolved. Most recent day first. " +
      "Requires orchestrator role.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "integer",
          description: "Days per page (default 30, max 365). Clamped, never rejected.",
          minimum: 1,
          maximum: 365,
        },
        offset: {
          type: "integer",
          description: "Days to skip. Default 0.",
          minimum: 0,
        },
      },
      required: [],
    },
  },
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
          description: "Max rows per page. Default 20, max 100.",
          minimum: 1,
          maximum: 100,
        },
        offset: {
          type: "integer",
          description: "Rows to skip — page the ranking past the first page. Default 0.",
          minimum: 0,
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
          description: "Max rows per page. Default 50, max 200.",
          minimum: 1,
          maximum: 200,
        },
        offset: {
          type: "integer",
          description: "Rows to skip — page the full unused set to completeness. Default 0.",
          minimum: 0,
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
    name: "signup",
    description:
      "Create a NEW agent-rooted (KB-tier) tenant and mint its one-time root API key — " +
      "entirely through this call, no human operator and no hardware authenticator required. " +
      "Public — no existing API key needed to call this tool. The returned tenant can " +
      "immediately use the FULL knowledge-wiki surface (ingest/search/context/curate, BYO " +
      "LLM key config, agent registration) but CANNOT perform work-breakdown / " +
      "chain-of-custody operations (create projects/epics/stories, claim/verify/report, " +
      "dispatch, etc.) — those require a separate, human-anchored tenant created via the " +
      "WebAuthn ceremony at https://loopctl.com/signup. Rate-limited per client IP " +
      "(<= 5 signups/hour). The raw_key in the response is shown ONCE — save it immediately " +
      "(e.g. as LOOPCTL_USER_KEY) since it cannot be retrieved again. Next steps after " +
      "signup: configure your BYO LLM keys with set_llm_config, then register an agent " +
      "identity, then ingest/search the wiki.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Tenant display name.", maxLength: 120 },
        slug: { type: "string", description: "URL-safe unique tenant slug.", maxLength: 64 },
        email: { type: "string", description: "Contact email for the tenant." },
      },
      required: ["name", "slug", "email"],
    },
  },
  {
    name: "request_authenticator_challenge",
    description:
      "Step 1 of the opt-in WebAuthn trust-tier upgrade ceremony (US-26.7.2): issues a " +
      "registration challenge for enrolling a hardware authenticator against an EXISTING " +
      "agent_rooted (KB-tier) tenant, promoting it to human_anchored on success. " +
      "IMPORTANT: completing this ceremony requires an INTERACTIVE WebAuthn client " +
      "(a browser calling navigator.credentials.create(), or a native FIDO2 library) " +
      "with a HUMAN present to physically touch the authenticator — an agent alone " +
      "cannot produce a valid attestation, by design. Use this tool to fetch the " +
      "challenge/rp/user/pubKeyCredParams payload, drive the WebAuthn ceremony in your " +
      "interactive client, then call enroll_authenticator with the result. If the " +
      "tenant is already human_anchored, the response includes reauth_required: true " +
      "plus a reauth_challenge — enroll_authenticator will need a fresh assertion from " +
      "an EXISTING authenticator too (see enroll_authenticator's description). Requires " +
      "LOOPCTL_USER_KEY (user role) bound to tenant_id.",
    inputSchema: {
      type: "object",
      properties: {
        tenant_id: { type: "string", description: "Tenant UUID to enroll an authenticator for." },
      },
      required: ["tenant_id"],
    },
  },
  {
    name: "enroll_authenticator",
    description:
      "Step 2 of the opt-in WebAuthn trust-tier upgrade ceremony: completes enrollment " +
      "with the attestation produced by navigator.credentials.create() against the " +
      "challenge from request_authenticator_challenge. On a tenant's FIRST enrollment " +
      "(zero prior authenticators) this call FLIPS the tenant from agent_rooted to " +
      "human_anchored, unlocking the work-breakdown / chain-of-custody surface " +
      "(projects, stories, dispatch, ...). On a SUBSEQUENT (backup) enrollment for an " +
      "already human_anchored tenant, `reauth_assertion` (a fresh WebAuthn assertion " +
      "from an EXISTING enrolled authenticator, from the challenge's reauth_challenge) " +
      "is REQUIRED — omitting it when required returns 401 reauth_required. All " +
      "binary fields are base64url encoded. Requires LOOPCTL_USER_KEY (user role) " +
      "bound to tenant_id. Cannot be completed by an agent alone — see " +
      "request_authenticator_challenge.",
    inputSchema: {
      type: "object",
      properties: {
        tenant_id: { type: "string", description: "Tenant UUID." },
        challenge_id: {
          type: "string",
          description: "challenge_id from request_authenticator_challenge.",
        },
        attestation_object: { type: "string", description: "Base64url attestation object." },
        client_data_json: { type: "string", description: "Base64url raw client data JSON." },
        credential_id: { type: "string", description: "Base64url credential id." },
        friendly_name: {
          type: "string",
          description: "Operator-supplied label (1..120 chars, default \"Authenticator\").",
        },
        reauth_assertion: {
          type: "object",
          description:
            "Required ONLY when enrolling a backup authenticator on an already " +
            "human_anchored tenant: a fresh assertion (challenge_id, credential_id, " +
            "authenticator_data, signature, client_data_json — all base64url) from an " +
            "EXISTING enrolled authenticator, bound to the reauth_challenge returned by " +
            "request_authenticator_challenge.",
        },
      },
      required: ["tenant_id", "challenge_id", "attestation_object", "client_data_json", "credential_id"],
    },
  },
  {
    name: "request_authenticator_revoke_challenge",
    description:
      "Issues a fresh-assertion challenge to authorize revoking one of a tenant's " +
      "enrolled WebAuthn authenticators. Requires an INTERACTIVE WebAuthn client + " +
      "human touch to produce the assertion revoke_authenticator needs — an agent " +
      "alone cannot authorize a revocation. Requires LOOPCTL_USER_KEY (user role) " +
      "bound to tenant_id.",
    inputSchema: {
      type: "object",
      properties: {
        tenant_id: { type: "string", description: "Tenant UUID." },
      },
      required: ["tenant_id"],
    },
  },
  {
    name: "revoke_authenticator",
    description:
      "Revokes an enrolled authenticator using the assertion from " +
      "request_authenticator_revoke_challenge (navigator.credentials.get() against an " +
      "EXISTING authenticator — human touch required). Refuses (409 last_authenticator) " +
      "to remove a human_anchored tenant's LAST authenticator — there is no " +
      "auto-downgrade; losing every authenticator is a fatal, human-recovery-only event " +
      "(docs/chain-of-custody-v2.md §9.3). Requires LOOPCTL_USER_KEY (user role) bound " +
      "to tenant_id.",
    inputSchema: {
      type: "object",
      properties: {
        tenant_id: { type: "string", description: "Tenant UUID." },
        authenticator_id: { type: "string", description: "UUID of the authenticator to revoke." },
        webauthn_assertion: {
          type: "object",
          description:
            "The assertion (challenge_id, credential_id, authenticator_data, signature, " +
            "client_data_json — all base64url) bound to the revoke-challenge.",
        },
      },
      required: ["tenant_id", "authenticator_id", "webauthn_assertion"],
    },
  },
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
// Context Retriever — dynamic per-tenant generated tools (US-30.5)
// ---------------------------------------------------------------------------
//
// Epic 30 lets a tenant declare ENTITIES whose schema auto-generates agent tools
// (`cr_filter_<entity>_by_<field>`, `cr_search_<entity>`) over governed loopctl
// data. Those specs are generated SERVER-SIDE per tenant, so the MCP server can't
// hard-code them in the static TOOLS array — it must fetch them at ListTools time
// and append them, then dispatch any unknown `cr_`-prefixed CallTool to one
// generic executor endpoint.
//
// Trust model: the stdio MCP process is ONE-TENANT-PER-PROCESS — the process key
// (LOOPCTL_AGENT_KEY) resolves to a tenant server-side, and GET /retrieve/tools
// returns ONLY that tenant's generated specs. The client never picks a tenant, so
// cross-tenant listing/calling is impossible by construction (AC-30.5.3). Both the
// listing fetch and the generic call ride the SAME `apiCall` path as static read
// tools, so they carry identical auth + witness/STH headers (AC-30.5.4).

// The generated-tools runtime (fetch + short-timeout/negative-TTL cache + generic
// dispatch) lives in lib/generated-tools.js so its caching/TTL/negative-cache and
// error-classification edge cases are exercised DIRECTLY by the test suite rather
// than a hand-copied mirror. We wire the SHIPPED `apiCall` + static tool names +
// `toContent` into it here. The process key (LOOPCTL_AGENT_KEY) is read per-call via
// a getter so it rides the SAME auth + witness/STH path as every static read tool
// (AC-30.5.4), and the static-name set powers the defense-in-depth drop of any spec
// that isn't `cr_`-prefixed or that collides with a built-in tool name.
const generatedToolsRuntime = createGeneratedToolsRuntime({
  apiCall,
  agentKey: () => process.env.LOOPCTL_AGENT_KEY,
  staticToolNames: new Set(TOOLS.map((t) => t.name)),
  toContent,
});

const { fetchGeneratedTools, callGeneratedTool } = generatedToolsRuntime;

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------

const server = new Server(
  {
    name: "loopctl",
    version: SERVER_VERSION,
  },
  {
    capabilities: { tools: {} },
  }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  // Static hand-maintained tools PLUS the calling tenant's per-tenant generated
  // Context Retriever tools (US-30.5). fetchGeneratedTools degrades to the static
  // tools (returns []/cache) on any fetch failure, so listing never errors.
  const generated = await fetchGeneratedTools();
  return { tools: [...TOOLS, ...generated] };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    // Project Tools
    case "get_tenant":
      return await getTenant();

    case "list_projects":
      return await listProjects(args);

    case "resolve_project":
      return await resolveProject(args);

    case "create_project":
      return await createProject(args);

    case "create_kb_scope":
      return await createKbScope(args);

    case "archive_kb_scope":
      return await archiveKbScope(args);

    case "restore_kb_scope":
      return await restoreKbScope(args);

    case "channel_post":
      return await channelPost(args);

    case "channel_recent":
      return await channelRecent(args);

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

    case "get_ingestion_anomalies":
      return await getIngestionAnomalies(args);

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

    case "knowledge_graph":
      return await knowledgeGraph(args);

    case "knowledge_suggest_links":
      return await knowledgeSuggestLinks(args);

    case "knowledge_distant_pairs":
      return await knowledgeDistantPairs(args);

    case "knowledge_novelty":
      return await knowledgeNovelty(args);

    case "knowledge_random_walk":
      return await knowledgeRandomWalk(args);

    case "knowledge_search":
      return await knowledgeSearch(args);

    case "knowledge_hybrid_search":
      return await knowledgeHybridSearch(args);

    case "knowledge_progressive_index":
      return await knowledgeProgressiveIndex(args);

    case "knowledge_progressive_drill":
      return await knowledgeProgressiveDrill(args);

    case "knowledge_list":
      return await knowledgeList(args);

    case "knowledge_get":
      return await knowledgeGet(args);

    case "knowledge_context":
      return await knowledgeContext(args);

    case "knowledge_create":
      return await knowledgeCreate(args);

    case "knowledge_update":
      return await knowledgeUpdate(args);

    // Agent Memory Tools
    case "memory_remember":
      return await memoryRemember(args);

    case "memory_recall":
      return await memoryRecall(args);
    case "recall_context":
      return await recallContext(args);

    case "memory_list":
      return await memoryList(args);

    case "memory_forget":
      return await memoryForget(args);

    case "memory_promote":
      return await memoryPromote(args);

    case "memory_graduate":
      return await memoryGraduate(args);

    // Knowledge Management Tools
    case "knowledge_publish":
      return await knowledgePublish(args);

    case "knowledge_bulk_publish":
      return await knowledgeBulkPublish(args);

    case "knowledge_bulk_unpublish":
      return await knowledgeBulkUnpublish(args);

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

    case "knowledge_conflicts":
      return await knowledgeConflicts(args);

    case "knowledge_resolve_conflict":
      return await knowledgeResolveConflict(args);

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
      return await knowledgeIngestionJobs(args);

    // Per-tenant BYO LLM config + usage (Epic 28, #179)
    case "llm_config":
      return await llmConfig();

    case "set_llm_config":
      return await setLlmConfig(args);

    case "knowledge_llm_usage":
      return await knowledgeLlmUsage(args);

    // Knowledge Analytics Tools
    case "knowledge_curation_log":
      return await knowledgeCurationLog(args);

    case "knowledge_retrieval_metrics":
      return await knowledgeRetrievalMetrics(args);

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

    case "signup":
      return await signup(args);

    case "request_authenticator_challenge":
      return await requestAuthenticatorChallenge(args);

    case "enroll_authenticator":
      return await enrollAuthenticator(args);

    case "request_authenticator_revoke_challenge":
      return await requestAuthenticatorRevokeChallenge(args);

    case "revoke_authenticator":
      return await revokeAuthenticator(args);

    case "get_sth":
      return await getSth(args);

    case "get_system_articles":
      return await getSystemArticles(args);

    case "recover_cap":
      return await recoverCap(args);

    case "get_acceptance_criteria":
      return await getAcceptanceCriteria(args);

    default:
      // Per-tenant generated Context Retriever tools (US-30.5) are not in the
      // static switch — dispatch any unknown `cr_`-prefixed name generically to
      // the /retrieve/:entity executor. Static tools are handled above, so this
      // never regresses them (AC-30.5.2).
      if (typeof name === "string" && name.startsWith(GENERATED_TOOL_PREFIX)) {
        return await callGeneratedTool(name, args);
      }
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
