/**
 * Tests for US-25.3: MCP Tool Context Parameters & agent_id Disambiguation
 *
 * Uses Node.js built-in test runner (node:test).
 * Run: node --test test/
 *
 * Strategy: The handler functions in index.js are not exported (it's a server
 * entry point with top-level await). We test the logic directly by reimplementing
 * the minimal helpers and handler bodies here, keeping the test self-contained
 * and resilient to refactors in the server bootstrap code.
 */

import { test, describe, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

// ---------------------------------------------------------------------------
// Minimal re-implementation of the helpers under test
// (mirrors index.js logic exactly)
// ---------------------------------------------------------------------------

function getBaseUrl() {
  return (process.env.LOOPCTL_SERVER || "https://loopctl.com").replace(/\/$/, "");
}

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

  const options = {
    method,
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
  };

  if (body !== undefined && body !== null) {
    options.body = JSON.stringify(body);
  }

  const response = await fetch(url, options);

  if (response.status === 204) return { ok: true };

  const contentType = response.headers.get("content-type") || "";
  let responseBody;
  if (contentType.includes("application/json")) {
    responseBody = await response.json();
  } else {
    responseBody = await response.text();
  }

  if (!response.ok) {
    return { error: true, status: response.status, body: responseBody };
  }

  return responseBody;
}

function toContent(result) {
  const isErr = result && result.error === true;
  return {
    content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    ...(isErr && { isError: true }),
  };
}

// Mirrors index.js llmRemediationNotice / withRemediationNotice exactly so the
// hybrid handler copy below exercises the SAME remediation-wrapping the real tool
// applies (the missing-embedding-key / keyword-only fallback surfacing the
// hybrid_search docstring promises). Without this the copy diverged from index.js
// (it ended at toContent) and the wrapper was covered by zero tests.
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

function withRemediationNotice(result) {
  const base = toContent(result);
  const notice = llmRemediationNotice(result);
  if (!notice) return base;
  return { ...base, content: [{ type: "text", text: notice }, ...base.content] };
}

// ---------------------------------------------------------------------------
// Handler implementations (mirror index.js exactly)
// ---------------------------------------------------------------------------

async function knowledgeIndex({ project_id, story_id, category, tags, offset, limit, fields }) {
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
  const counts = result?.meta?.counts;
  if (counts && (counts.not_found > 0 || counts.errored > 0)) {
    return {
      content: [{ type: "text", text: "WARNING: partial" }, ...toContent(result).content],
    };
  }
  return toContent(result);
}

async function knowledgeList({
  project_id,
  category,
  status,
  tags,
  source_type,
  source_id,
  idempotency_key,
  limit,
  offset,
}) {
  const params = new URLSearchParams();
  if (project_id) params.set("project_id", project_id);
  if (category) params.set("category", category);
  if (status) params.set("status", status);
  if (tags) params.set("tags", tags);
  if (source_type) params.set("source_type", source_type);
  if (source_id) params.set("source_id", source_id);
  if (idempotency_key) params.set("idempotency_key", idempotency_key);
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  const result = await apiCall(
    "GET",
    `/api/v1/articles?${params}`,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

async function knowledgeSearch({ q, project_id, story_id, category, tags, mode, limit, offset }) {
  const params = new URLSearchParams();
  if (q != null && q !== "") params.set("q", q);
  if (project_id) params.set("project_id", project_id);
  if (story_id) params.set("story_id", story_id);
  if (category) params.set("category", category);
  if (tags) params.set("tags", tags);
  if (mode) params.set("mode", mode);
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  const result = await apiCall("GET", `/api/v1/knowledge/search?${params}`, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

// US-31.4 — mirrors index.js knowledgeHybridSearch (POST, agent key, JSON body).
// Ends with withRemediationNotice (NOT toContent) to match the real handler: the
// combined pool underneath can degrade to keyword-only with a meta.remediation the
// tool must surface prominently.
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
  return withRemediationNotice(result);
}

// US-31.4 — mirrors index.js knowledgeProgressiveIndex (GET, agent key).
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

// US-31.4 — mirrors index.js knowledgeProgressiveDrill (GET, agent key).
async function knowledgeProgressiveDrill({ article_id }) {
  const result = await apiCall(
    "GET",
    `/api/v1/knowledge/progressive/${article_id}`,
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

async function knowledgeCreate({ title, body, category, tags, project_id, draft, force }) {
  const payload = { title, body };
  if (category) payload.category = category;
  if (tags) payload.tags = tags;
  if (project_id) payload.project_id = project_id;

  // Articles publish on create by default for every role (including agent), so a
  // plain create routes through the agent key and is immediately visible. Pass
  // draft:true to stage it for later review instead.
  if (draft) payload.draft = true;

  // The server-side novelty gate dedups the proposal; force:true bypasses it.
  if (force) payload.force = true;

  const result = await apiCall(
    "POST",
    "/api/v1/articles",
    payload,
    process.env.LOOPCTL_AGENT_KEY,
  );
  return toContent(result);
}

// #331 — mirrors index.js knowledgeUpdate (PATCH, agent key, only-provided-fields).
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

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

async function knowledgeAgentUsage({ api_key_id, agent_id, limit, since_days } = {}) {
  const normalizedApiKeyId =
    typeof api_key_id === "string" && api_key_id.trim() === "" ? null : api_key_id;
  const normalizedAgentId =
    typeof agent_id === "string" && agent_id.trim() === "" ? null : agent_id;

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

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const AGENT_KEY = "lc_test_agent_key";
const ORCH_KEY = "lc_test_orch_key";
const BASE_URL = "https://loopctl.com";

/** Installs a mock fetch that captures calls and returns a canned JSON response. */
function mockFetch(responseBody = { ok: true }, status = 200) {
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: () => "application/json" },
      json: async () => responseBody,
      text: async () => JSON.stringify(responseBody),
    };
  };
  return calls;
}

function setupEnv() {
  process.env.LOOPCTL_SERVER = BASE_URL;
  process.env.LOOPCTL_AGENT_KEY = AGENT_KEY;
  process.env.LOOPCTL_ORCH_KEY = ORCH_KEY;
  delete process.env.LOOPCTL_API_KEY;
}

// ---------------------------------------------------------------------------
// TC-25.3.1: knowledge_search forwards project_id and story_id
// ---------------------------------------------------------------------------

describe("TC-25.3.1: knowledge_search with project_id and story_id", () => {
  test("forwards both attribution params to HTTP request", async () => {
    setupEnv();
    const calls = mockFetch({ articles: [] });

    const result = await knowledgeSearch({
      q: "csv import",
      project_id: "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0",
      story_id: "89aa0c48-5cf5-4925-b164-21684ef79c4d",
    });

    assert.equal(calls.length, 1, "exactly one HTTP call made");
    const { url, options } = calls[0];

    // Verify method
    assert.equal(options.method, "GET");

    // Verify Authorization header uses agent key
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);

    // Verify query params
    const parsedUrl = new URL(url);
    assert.equal(parsedUrl.searchParams.get("q"), "csv import");
    assert.equal(parsedUrl.searchParams.get("project_id"), "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0");
    assert.equal(parsedUrl.searchParams.get("story_id"), "89aa0c48-5cf5-4925-b164-21684ef79c4d");

    // Verify no error in result
    assert.equal(result.isError, undefined);
  });
});

// ---------------------------------------------------------------------------
// TC-25.3.2: knowledge_search omits project_id/story_id when not passed
// ---------------------------------------------------------------------------

describe("TC-25.3.2: knowledge_search without attribution params", () => {
  test("omits project_id and story_id from URL", async () => {
    setupEnv();
    const calls = mockFetch({ articles: [] });

    await knowledgeSearch({ q: "csv import" });

    assert.equal(calls.length, 1);
    const parsedUrl = new URL(calls[0].url);
    assert.equal(parsedUrl.searchParams.has("project_id"), false, "no project_id param");
    assert.equal(parsedUrl.searchParams.has("story_id"), false, "no story_id param");
    assert.equal(parsedUrl.searchParams.get("q"), "csv import");
  });
});

// ---------------------------------------------------------------------------
// TC-25.3.3: knowledge_agent_usage with api_key_id
// ---------------------------------------------------------------------------

describe("TC-25.3.3: knowledge_agent_usage with api_key_id", () => {
  test("routes to analytics endpoint with api_key_id, no deprecation warning", async () => {
    setupEnv();
    const calls = mockFetch({ reads: 31, articles: [] });

    const result = await knowledgeAgentUsage({
      api_key_id: "b977c90c-061b-4e42-8afa-26a5efde51ad",
      since_days: 7,
    });

    assert.equal(calls.length, 1);
    const parsedUrl = new URL(calls[0].url);

    // Path should include the api_key_id
    assert.ok(
      parsedUrl.pathname.includes("b977c90c-061b-4e42-8afa-26a5efde51ad"),
      `pathname ${parsedUrl.pathname} should include api_key_id`
    );
    assert.equal(parsedUrl.searchParams.get("since_days"), "7");
    assert.equal(result.isError, undefined, "no error");
    assert.equal(result._meta, undefined, "no deprecation warning for api_key_id path");
  });
});

// ---------------------------------------------------------------------------
// TC-25.3.4: knowledge_agent_usage with agent_id (logical identity)
// ---------------------------------------------------------------------------

describe("TC-25.3.4: knowledge_agent_usage with agent_id (logical agents.id)", () => {
  test("routes to analytics endpoint with agent_id, includes deprecation hint", async () => {
    setupEnv();
    const calls = mockFetch({ reads: 5, articles: [] });

    const result = await knowledgeAgentUsage({
      agent_id: "09429bc4-328f-42f4-acec-db48b40849b2",
      since_days: 7,
    });

    assert.equal(calls.length, 1);
    const parsedUrl = new URL(calls[0].url);

    assert.ok(
      parsedUrl.pathname.includes("09429bc4-328f-42f4-acec-db48b40849b2"),
      `pathname ${parsedUrl.pathname} should include agent_id`
    );
    assert.equal(parsedUrl.searchParams.get("since_days"), "7");
    assert.equal(result.isError, undefined, "no error");

    // Deprecation hint should be present for agent_id-only calls
    assert.ok(result._meta, "deprecation _meta should be present");
    assert.ok(
      result._meta.deprecation_hint.includes("api_key_id"),
      "deprecation hint should mention api_key_id"
    );
    assert.ok(
      result._meta.deprecation_hint.includes("agents.id"),
      "deprecation hint should mention agents.id"
    );
  });
});

// ---------------------------------------------------------------------------
// TC-25.3.5: knowledge_agent_usage errors when BOTH are passed
// ---------------------------------------------------------------------------

describe("TC-25.3.5: knowledge_agent_usage with both api_key_id and agent_id", () => {
  test("returns validation error without making HTTP request", async () => {
    setupEnv();
    const calls = mockFetch();

    const result = await knowledgeAgentUsage({
      api_key_id: "b977c90c-061b-4e42-8afa-26a5efde51ad",
      agent_id: "09429bc4-328f-42f4-acec-db48b40849b2",
      since_days: 7,
    });

    assert.equal(calls.length, 0, "no HTTP request should be made");
    assert.equal(result.isError, true);
    assert.ok(
      result.content[0].text.includes("pass exactly one of api_key_id or agent_id"),
      "error message should instruct user to pass exactly one"
    );
  });
});

// ---------------------------------------------------------------------------
// TC-25.3.6: knowledge_agent_usage errors when NEITHER is passed
// ---------------------------------------------------------------------------

describe("TC-25.3.6: knowledge_agent_usage with neither api_key_id nor agent_id", () => {
  test("returns validation error without making HTTP request", async () => {
    setupEnv();
    const calls = mockFetch();

    const result = await knowledgeAgentUsage({ since_days: 7 });

    assert.equal(calls.length, 0, "no HTTP request should be made");
    assert.equal(result.isError, true);
    assert.ok(
      result.content[0].text.includes("pass exactly one of api_key_id or agent_id"),
      "error message should instruct user to pass exactly one"
    );
  });
});

// ---------------------------------------------------------------------------
// TC-25.3.7: Deprecation hint when agent_id is passed alone
// ---------------------------------------------------------------------------

describe("TC-25.3.7: deprecation hint for agent_id-only call", () => {
  test("_meta.deprecation_hint nudges toward api_key_id when agent_id alone is used", async () => {
    setupEnv();
    mockFetch({ reads: 10, articles: [] });

    const result = await knowledgeAgentUsage({
      agent_id: "09429bc4-328f-42f4-acec-db48b40849b2",
    });

    assert.equal(result.isError, undefined, "not an error");
    assert.ok(result._meta, "_meta should be present");
    assert.ok(typeof result._meta.deprecation_hint === "string", "deprecation_hint should be a string");
    assert.ok(
      result._meta.deprecation_hint.includes("api_key_id"),
      "hint should mention api_key_id"
    );
    // Hint should be in _meta, not polluting content
    const contentText = result.content[0].text;
    assert.ok(!contentText.includes("deprecation"), "deprecation hint should NOT be in content array");
  });
});

// ---------------------------------------------------------------------------
// TC-25.3.7b: knowledge_agent_usage treats empty strings as missing
// ---------------------------------------------------------------------------

describe("TC-25.3.7b: empty-string api_key_id/agent_id are rejected as missing", () => {
  test("empty string api_key_id alone triggers neither-provided validation error", async () => {
    setupEnv();
    const calls = mockFetch();

    const result = await knowledgeAgentUsage({ api_key_id: "" });

    assert.equal(calls.length, 0, "no HTTP request should be made for empty string id");
    assert.equal(result.isError, true);
    assert.ok(
      result.content[0].text.includes("pass exactly one of api_key_id or agent_id"),
      "empty string should surface the neither-provided error"
    );
  });

  test("whitespace-only agent_id is treated as missing", async () => {
    setupEnv();
    const calls = mockFetch();

    const result = await knowledgeAgentUsage({ agent_id: "   " });

    assert.equal(calls.length, 0, "no HTTP request should be made for whitespace-only id");
    assert.equal(result.isError, true);
  });

  test("empty string on both sides still produces an error rather than a malformed URL", async () => {
    setupEnv();
    const calls = mockFetch();

    const result = await knowledgeAgentUsage({ api_key_id: "", agent_id: "" });

    assert.equal(calls.length, 0, "no HTTP request when both are empty strings");
    assert.equal(result.isError, true);
  });
});

// ---------------------------------------------------------------------------
// TC-25.3.7c: knowledge_agent_usage rejects non-UUID resolvedId values
// (defense-in-depth against URL path injection)
// ---------------------------------------------------------------------------

describe("TC-25.3.7c: non-UUID ids are rejected before a network call is made", () => {
  test("path-traversal-style api_key_id is rejected client-side", async () => {
    setupEnv();
    const calls = mockFetch();

    const result = await knowledgeAgentUsage({
      api_key_id: "../../../stories/123",
    });

    assert.equal(calls.length, 0, "no HTTP request should be made for non-UUID id");
    assert.equal(result.isError, true);
    assert.ok(
      result.content[0].text.includes("canonical UUID"),
      "error should mention the UUID constraint"
    );
  });

  test("hex-but-wrong-shape agent_id is rejected", async () => {
    setupEnv();
    const calls = mockFetch();

    const result = await knowledgeAgentUsage({ agent_id: "deadbeef" });

    assert.equal(calls.length, 0, "no HTTP request for malformed id");
    assert.equal(result.isError, true);
  });

  test("numeric id is rejected", async () => {
    setupEnv();
    const calls = mockFetch();

    const result = await knowledgeAgentUsage({ api_key_id: 42 });

    assert.equal(calls.length, 0);
    assert.equal(result.isError, true);
  });

  test("valid canonical UUID passes the check", async () => {
    setupEnv();
    const calls = mockFetch({ reads: 1, articles: [] });

    const result = await knowledgeAgentUsage({
      api_key_id: "b977c90c-061b-4e42-8afa-26a5efde51ad",
    });

    assert.equal(calls.length, 1, "HTTP request should proceed for valid UUID");
    assert.equal(result.isError, undefined);
  });
});

// ---------------------------------------------------------------------------
// TC-25.3.8: README contains Wiki Attribution section
// ---------------------------------------------------------------------------

describe("TC-25.3.8: README Wiki Attribution section", () => {
  test("README.md contains required Wiki Attribution content", () => {
    const __dirname = path.dirname(fileURLToPath(import.meta.url));
    const readmePath = path.join(__dirname, "..", "README.md");
    const readme = readFileSync(readmePath, "utf8");

    // Section heading
    assert.ok(readme.includes("Wiki Attribution"), 'README should include "Wiki Attribution" heading');

    // api_key_id vs agent_id disambiguation
    assert.ok(readme.includes("api_key_id"), 'README should explain api_key_id parameter');
    assert.ok(readme.includes("agent_id"), 'README should explain agent_id parameter');

    // story_id context params
    assert.ok(readme.includes("story_id"), 'README should mention story_id parameter');
    assert.ok(readme.includes("project_id"), 'README should mention project_id parameter');

    // JSON example with story_id for knowledge_search
    assert.ok(
      readme.includes("knowledge_search") && readme.includes("story_id"),
      'README should have knowledge_search example with story_id'
    );

    // Deprecation note
    assert.ok(
      readme.includes("deprecated") || readme.includes("Deprecated"),
      'README should mention deprecated behavior'
    );
  });
});

// ---------------------------------------------------------------------------
// OKF export/import tools — re-implemented handlers (mirror index.js)
// ---------------------------------------------------------------------------

import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";

async function knowledgeOkfExport({ project_id, out_dir }) {
  const basePath = project_id
    ? `/api/v1/projects/${project_id}/knowledge/okf/export`
    : "/api/v1/knowledge/okf/export";
  const result = await apiCall("GET", `${basePath}?format=json`, null, process.env.LOOPCTL_USER_KEY);
  if (result.error) return toContent(result);
  const bundle = result.data || result;
  const files = bundle.files || {};
  const meta = bundle.meta || {};
  if (!out_dir) return toContent({ meta, file_count: Object.keys(files).length, files });
  return toContent({ meta, out_dir, written: Object.keys(files).length });
}

async function knowledgeOkfImport({ bundle_dir, project_id, merge, dry_run }) {
  const nodePath = await import("node:path");
  const fs = await import("node:fs/promises");
  const files = {};
  async function walk(dir) {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const abs = nodePath.join(dir, entry.name);
      if (entry.isDirectory()) await walk(abs);
      else if (entry.isFile() && entry.name.endsWith(".md")) {
        files[nodePath.relative(bundle_dir, abs).split(nodePath.sep).join("/")] =
          await fs.readFile(abs, "utf8");
      }
    }
  }
  await walk(bundle_dir);
  const payload = { files };
  if (project_id) payload.project_id = project_id;
  if (merge != null) payload.merge = merge;
  if (dry_run != null) payload.dry_run = dry_run;
  const result = await apiCall("POST", "/api/v1/knowledge/okf/import", payload, process.env.LOOPCTL_USER_KEY);
  return toContent(result);
}

describe("knowledge_okf_export", () => {
  test("requests the JSON bundle with the user key and returns files inline", async () => {
    setupEnv();
    process.env.LOOPCTL_USER_KEY = "lc_test_user_key";
    const calls = mockFetch({ data: { files: { "index.md": "# Bundle\n" }, meta: { okf_version: "0.1" } } });

    const res = await knowledgeOkfExport({});

    assert.equal(calls.length, 1);
    const url = new URL(calls[0].url);
    assert.equal(url.pathname, "/api/v1/knowledge/okf/export");
    assert.equal(url.searchParams.get("format"), "json");
    assert.equal(calls[0].options.headers.Authorization, "Bearer lc_test_user_key");
    const payload = JSON.parse(res.content[0].text);
    assert.equal(payload.file_count, 1);
  });

  test("uses the project-scoped path when project_id is given", async () => {
    setupEnv();
    process.env.LOOPCTL_USER_KEY = "lc_test_user_key";
    const calls = mockFetch({ data: { files: {}, meta: {} } });
    await knowledgeOkfExport({ project_id: "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0" });
    const url = new URL(calls[0].url);
    assert.equal(
      url.pathname,
      "/api/v1/projects/b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0/knowledge/okf/export"
    );
  });
});

describe("knowledge_okf_import", () => {
  test("walks a directory of .md files and POSTs them as a files map", async () => {
    setupEnv();
    process.env.LOOPCTL_USER_KEY = "lc_test_user_key";

    const dir = mkdtempSync(`${tmpdir()}/okf-`);
    mkdirSync(`${dir}/reference`, { recursive: true });
    writeFileSync(`${dir}/reference/a.md`, "---\ntype: reference\ntitle: A\n---\n\nbody\n");
    writeFileSync(`${dir}/index.md`, "# Bundle\n");

    const calls = mockFetch({ data: { created: 1, errors: [] } });
    await knowledgeOkfImport({ bundle_dir: dir, merge: true });

    assert.equal(calls.length, 1);
    assert.equal(calls[0].options.method, "POST");
    assert.equal(calls[0].options.headers.Authorization, "Bearer lc_test_user_key");
    const body = JSON.parse(calls[0].options.body);
    assert.ok(body.files["reference/a.md"].includes("type: reference"));
    assert.ok(body.files["index.md"]);
    assert.equal(body.merge, true);
  });
});

// ---------------------------------------------------------------------------
// Issue #108: knowledge_search enumeration (q optional + offset)
// ---------------------------------------------------------------------------

describe("Issue #108: knowledge_search list mode (q optional)", () => {
  test("omits q from URL when q is absent but tags supplied", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: { total_count: 0 } });

    await knowledgeSearch({ tags: "hub", limit: 50, offset: 100 });

    assert.equal(calls.length, 1);
    const url = new URL(calls[0].url);
    assert.equal(url.searchParams.has("q"), false, "q omitted when not provided");
    assert.equal(url.searchParams.get("tags"), "hub");
    assert.equal(url.searchParams.get("limit"), "50");
    assert.equal(url.searchParams.get("offset"), "100");
  });

  test("omits empty-string q from URL", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: {} });

    await knowledgeSearch({ q: "", category: "reference" });

    const url = new URL(calls[0].url);
    assert.equal(url.searchParams.has("q"), false, "empty q omitted");
    assert.equal(url.searchParams.get("category"), "reference");
  });

  test("forwards offset for keyword search pagination", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: {} });

    await knowledgeSearch({ q: "elixir", offset: 20 });

    const url = new URL(calls[0].url);
    assert.equal(url.searchParams.get("q"), "elixir");
    assert.equal(url.searchParams.get("offset"), "20");
  });
});

// ---------------------------------------------------------------------------
// Issue #109: knowledge_index filtering + pagination
// ---------------------------------------------------------------------------

describe("Issue #109: knowledge_index category/tags/offset/limit", () => {
  test("forwards category, tags, offset, and limit", async () => {
    setupEnv();
    const calls = mockFetch({ data: {}, meta: { total_count: 0 } });

    await knowledgeIndex({
      category: "reference",
      tags: "hub",
      offset: 50,
      limit: 200,
    });

    assert.equal(calls.length, 1);
    const url = new URL(calls[0].url);
    assert.equal(url.pathname, "/api/v1/knowledge/index");
    assert.equal(url.searchParams.get("category"), "reference");
    assert.equal(url.searchParams.get("tags"), "hub");
    assert.equal(url.searchParams.get("offset"), "50");
    assert.equal(url.searchParams.get("limit"), "200");
  });

  test("forwards pagination on the project-scoped path", async () => {
    setupEnv();
    const calls = mockFetch({ data: {}, meta: {} });

    await knowledgeIndex({
      project_id: "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0",
      offset: 0,
      limit: 1000,
    });

    const url = new URL(calls[0].url);
    assert.equal(
      url.pathname,
      "/api/v1/projects/b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0/knowledge/index"
    );
    assert.equal(url.searchParams.get("limit"), "1000");
  });

  test("omits filter params when none supplied", async () => {
    setupEnv();
    const calls = mockFetch({ data: {}, meta: {} });

    await knowledgeIndex({});

    const url = new URL(calls[0].url);
    assert.equal(url.searchParams.has("category"), false);
    assert.equal(url.searchParams.has("tags"), false);
    assert.equal(url.searchParams.has("offset"), false);
    assert.equal(url.searchParams.has("limit"), false);
    assert.equal(url.searchParams.has("fields"), false);
  });
});

describe("Issue #117: knowledge_index fields projection", () => {
  test("forwards fields as a comma-separated array", async () => {
    setupEnv();
    const calls = mockFetch({ data: {}, meta: {} });

    await knowledgeIndex({ fields: ["id", "title", "tags"] });

    const url = new URL(calls[0].url);
    assert.equal(url.searchParams.get("fields"), "id,title,tags");
  });

  test("accepts fields as a pre-joined string", async () => {
    setupEnv();
    const calls = mockFetch({ data: {}, meta: {} });

    await knowledgeIndex({ fields: "id,updated_at" });

    const url = new URL(calls[0].url);
    assert.equal(url.searchParams.get("fields"), "id,updated_at");
  });
});

describe("Issue #118: knowledge_stats", () => {
  test("routes to the tenant-wide stats endpoint with the agent key", async () => {
    setupEnv();
    const calls = mockFetch({ total: 0, by_category: {}, by_status: {} });

    await knowledgeStats({});

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(new URL(url).pathname, "/api/v1/knowledge/stats");
    assert.equal(options.method, "GET");
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
  });

  test("routes to the project-scoped stats endpoint when project_id is given", async () => {
    setupEnv();
    const calls = mockFetch({ total: 0, by_category: {}, by_status: {} });

    await knowledgeStats({ project_id: "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0" });

    assert.equal(
      new URL(calls[0].url).pathname,
      "/api/v1/projects/b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0/knowledge/stats"
    );
  });

  test("rejects a non-UUID project_id client-side without a network call", async () => {
    setupEnv();
    const calls = mockFetch({ total: 0 });

    // A path-traversal-style value must never reach fetch().
    const result = await knowledgeStats({ project_id: "../../admin" });

    assert.equal(result.isError, true);
    assert.equal(calls.length, 0, "no HTTP request should be made");
  });

  test("knowledge_index also rejects a non-UUID project_id client-side", async () => {
    setupEnv();
    const calls = mockFetch({ data: {}, meta: {} });

    const result = await knowledgeIndex({ project_id: "not-a-uuid" });

    assert.equal(result.isError, true);
    assert.equal(calls.length, 0);
  });
});

describe("knowledge_create: publish-on-create by default (#133)", () => {
  test("a default create uses the agent key and sends no draft/publish flag", async () => {
    setupEnv();
    const calls = mockFetch({ data: { status: "published" }, note: "published" });

    await knowledgeCreate({ title: "T", body: "B", category: "pattern" });

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(new URL(url).pathname, "/api/v1/articles");
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
    const sent = JSON.parse(options.body);
    assert.equal(sent.draft, undefined);
    assert.equal(sent.publish, undefined, "the removed publish flag must never be sent");
  });

  test("draft: true stages a draft on the agent key (no orchestrator key consulted)", async () => {
    setupEnv();
    const calls = mockFetch({ data: { status: "draft" }, note: "draft" });

    await knowledgeCreate({ title: "T", body: "B", category: "pattern", draft: true });

    assert.equal(calls.length, 1);
    const { options } = calls[0];
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
    const sent = JSON.parse(options.body);
    assert.equal(sent.draft, true);
    assert.equal(sent.publish, undefined);
  });

  test("draft: false is the same as omitting it — publishes on the agent key", async () => {
    setupEnv();
    const calls = mockFetch({ data: { status: "published" } });

    await knowledgeCreate({ title: "T", body: "B", category: "pattern", draft: false });

    assert.equal(calls.length, 1);
    const { options } = calls[0];
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
    assert.equal(JSON.parse(options.body).draft, undefined);
  });

  test("publishing on create needs no orchestrator key (agent-only install works)", async () => {
    setupEnv();
    delete process.env.LOOPCTL_ORCH_KEY;
    delete process.env.LOOPCTL_API_KEY;
    const calls = mockFetch({ data: { status: "published" } });

    const result = await knowledgeCreate({ title: "T", body: "B", category: "pattern" });

    assert.equal(result.isError, undefined, "default publish-on-create must not error");
    assert.equal(calls.length, 1);
    assert.equal(calls[0].options.headers.Authorization, `Bearer ${AGENT_KEY}`);
  });
});

describe("knowledge_update: in-place edit on the agent key (#331)", () => {
  test("PATCHes /api/v1/articles/:id on the agent key, ID preserved in the path", async () => {
    setupEnv();
    const id = "11111111-1111-1111-1111-111111111111";
    const calls = mockFetch({ data: { id, title: "New" } });

    await knowledgeUpdate({ article_id: id, title: "New", body: "b" });

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(new URL(url).pathname, `/api/v1/articles/${id}`);
    assert.equal(options.method, "PATCH");
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
  });

  test("sends only the provided fields (partial update)", async () => {
    setupEnv();
    const id = "22222222-2222-2222-2222-222222222222";
    const calls = mockFetch({ data: { id } });

    await knowledgeUpdate({ article_id: id, body: "only body", tags: ["x"] });

    const sent = JSON.parse(calls[0].options.body);
    assert.deepEqual(sent, { body: "only body", tags: ["x"] });
    assert.equal(sent.title, undefined);
    assert.equal(sent.category, undefined);
  });

  test("works on an agent-only install (no user/orch key consulted)", async () => {
    setupEnv();
    delete process.env.LOOPCTL_USER_KEY;
    delete process.env.LOOPCTL_ORCH_KEY;
    const id = "33333333-3333-3333-3333-333333333333";
    const calls = mockFetch({ data: { id } });

    const result = await knowledgeUpdate({ article_id: id, title: "T" });

    assert.equal(result.isError, undefined);
    assert.equal(calls[0].options.headers.Authorization, `Bearer ${AGENT_KEY}`);
  });
});

describe("knowledge_list: lag-free enumeration (#134/#135)", () => {
  test("routes to GET /api/v1/articles on the agent key", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: { total_count: 0 } });

    await knowledgeList({});

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(new URL(url).pathname, "/api/v1/articles");
    assert.equal(options.method, "GET");
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
  });

  test("forwards every filter as a query param (no dropped params)", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: { total_count: 0 } });

    await knowledgeList({
      project_id: "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0",
      category: "reference",
      status: "published",
      tags: "a,b",
      source_type: "web_article",
      source_id: "11111111-1111-1111-1111-111111111111",
      idempotency_key: "ik-1",
      limit: 50,
      offset: 100,
    });

    const q = new URL(calls[0].url).searchParams;
    assert.equal(q.get("project_id"), "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0");
    assert.equal(q.get("category"), "reference");
    assert.equal(q.get("status"), "published");
    assert.equal(q.get("tags"), "a,b");
    assert.equal(q.get("source_type"), "web_article");
    assert.equal(q.get("source_id"), "11111111-1111-1111-1111-111111111111");
    assert.equal(q.get("idempotency_key"), "ik-1");
    assert.equal(q.get("limit"), "50");
    assert.equal(q.get("offset"), "100");
  });

  test("omits unset filters", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: { total_count: 0 } });

    await knowledgeList({ idempotency_key: "only-this" });

    const q = new URL(calls[0].url).searchParams;
    assert.equal(q.get("idempotency_key"), "only-this");
    assert.equal(q.get("source_type"), null);
    assert.equal(q.get("status"), null);
  });
});

describe("knowledge_bulk_delete (#136)", () => {
  test("routes to POST /api/v1/knowledge/bulk-delete on the user key with article_ids", async () => {
    setupEnv();
    process.env.LOOPCTL_USER_KEY = "lc_test_user_key";
    const calls = mockFetch({ data: [], meta: { count: 0, counts: {}, results: [] } });

    await knowledgeBulkDelete({ article_ids: ["11111111-1111-1111-1111-111111111111"] });

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(new URL(url).pathname, "/api/v1/knowledge/bulk-delete");
    assert.equal(options.method, "POST");
    assert.equal(options.headers.Authorization, "Bearer lc_test_user_key");
    assert.deepEqual(JSON.parse(options.body).article_ids, [
      "11111111-1111-1111-1111-111111111111",
    ]);
  });

  test("forwards the source and tag selectors", async () => {
    setupEnv();
    process.env.LOOPCTL_USER_KEY = "lc_test_user_key";
    const calls = mockFetch({ data: [], meta: { count: 0, counts: {}, results: [] } });

    await knowledgeBulkDelete({ source_type: "web_article", source_id: "s", tag: "t", confirm: true });

    const sent = JSON.parse(calls[0].options.body);
    assert.equal(sent.source_type, "web_article");
    assert.equal(sent.source_id, "s");
    assert.equal(sent.tag, "t");
    assert.equal(sent.confirm, true);
    assert.equal(sent.article_ids, undefined);
  });

  test("prepends a warning when the run is partial (not_found/errored > 0)", async () => {
    setupEnv();
    process.env.LOOPCTL_USER_KEY = "lc_test_user_key";
    mockFetch({
      data: [],
      meta: { count: 0, counts: { archived: 0, skipped: 0, not_found: 1, errored: 0 }, results: [] },
    });

    const result = await knowledgeBulkDelete({ article_ids: ["x"] });
    assert.match(result.content[0].text, /WARNING/);
  });

  test("forwards the dry_run / hard / token / confirm_hash flow (US-27.12)", async () => {
    setupEnv();
    process.env.LOOPCTL_USER_KEY = "lc_test_user_key";
    const calls = mockFetch({ data: { would_affect: 2 }, meta: { would_affect: 2, token: "tok-1" } });

    await knowledgeBulkDelete({
      tag: "cleanup",
      confirm: true,
      dry_run: true,
      hard: true,
      token: "tok-1",
      confirm_hash: "abc",
    });

    const sent = JSON.parse(calls[0].options.body);
    assert.equal(sent.dry_run, true);
    assert.equal(sent.hard, true);
    assert.equal(sent.token, "tok-1");
    assert.equal(sent.confirm_hash, "abc");
    assert.equal(sent.tag, "cleanup");
  });

  test("does NOT warn on a dry-run / hard response (no meta.counts)", async () => {
    setupEnv();
    process.env.LOOPCTL_USER_KEY = "lc_test_user_key";
    mockFetch({ data: { affected: 2 }, meta: { affected: 2, op: "delete" } });

    const result = await knowledgeBulkDelete({ hard: true, token: "tok-1" });
    assert.doesNotMatch(result.content[0].text, /WARNING/);
  });
});

describe("knowledge_create novelty gate (force passthrough)", () => {
  test("omits force by default so the gate stays on", async () => {
    setupEnv();
    const calls = mockFetch({ data: { id: "x" } });

    await knowledgeCreate({ title: "T", body: "B" });

    const sent = JSON.parse(calls[0].options.body);
    assert.equal(sent.force, undefined);
  });

  test("forwards force: true to bypass the gate", async () => {
    setupEnv();
    const calls = mockFetch({ data: { id: "x" } });

    await knowledgeCreate({ title: "T", body: "B", force: true });

    const sent = JSON.parse(calls[0].options.body);
    assert.equal(sent.force, true);
  });
});

async function knowledgeConflicts({ limit, offset } = {}) {
  const params = new URLSearchParams();
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  const qs = params.toString();
  const path = qs
    ? `/api/v1/knowledge/conflicts?${qs}`
    : "/api/v1/knowledge/conflicts";
  return await apiCall("GET", path, null, process.env.LOOPCTL_AGENT_KEY);
}

async function knowledgeResolveConflict({
  source_article_id,
  target_article_id,
  disposition,
  authoritative_article_id,
  classification,
  evidence,
  confidence,
} = {}) {
  const payload = { source_article_id, target_article_id, disposition };
  if (authoritative_article_id) payload.authoritative_article_id = authoritative_article_id;
  if (classification) payload.classification = classification;
  if (evidence) payload.evidence = evidence;
  if (confidence) payload.confidence = confidence;
  return await apiCall(
    "POST",
    "/api/v1/knowledge/conflicts/resolve",
    payload,
    process.env.LOOPCTL_AGENT_KEY,
  );
}

describe("knowledge_resolve_conflict (verdict passthrough)", () => {
  test("POSTs the verdict with the agent key and only the provided fields", async () => {
    setupEnv();
    const calls = mockFetch({ data: { id: "r1", disposition: "supersede", executed: false } }, 201);

    await knowledgeResolveConflict({
      source_article_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      target_article_id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      disposition: "supersede",
      authoritative_article_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      confidence: "high",
    });

    const { url, options } = calls[0];
    assert.equal(options.method, "POST");
    assert.equal(new URL(url).pathname, "/api/v1/knowledge/conflicts/resolve");
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
    const sent = JSON.parse(options.body);
    assert.equal(sent.disposition, "supersede");
    assert.equal(sent.authoritative_article_id, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
    assert.equal(sent.confidence, "high");
    // Omitted optionals aren't sent.
    assert.equal(sent.evidence, undefined);
    assert.equal(sent.classification, undefined);
  });
});

describe("knowledge_conflicts (route-the-findings review surface)", () => {
  test("GETs the conflicts endpoint with the agent key and forwards pagination", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: { total_count: 0 } });

    await knowledgeConflicts({ limit: 10, offset: 20 });

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(options.method, "GET");
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
    const parsed = new URL(url);
    assert.equal(parsed.pathname, "/api/v1/knowledge/conflicts");
    assert.equal(parsed.searchParams.get("limit"), "10");
    assert.equal(parsed.searchParams.get("offset"), "20");
  });

  test("omits the query string when no pagination is passed", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: { total_count: 0 } });

    await knowledgeConflicts();

    const parsed = new URL(calls[0].url);
    assert.equal(parsed.pathname, "/api/v1/knowledge/conflicts");
    assert.equal(parsed.search, "");
  });
});

// ---------------------------------------------------------------------------
// US-31.4: hybrid retrieval + progressive disclosure MCP tools (TC-31.4.2)
// ---------------------------------------------------------------------------

describe("US-31.4: knowledge_hybrid_search", () => {
  test("POSTs the query as a JSON body with the agent key", async () => {
    setupEnv();
    const calls = mockFetch({
      data: [{ id: "a1", title: "Refund Policy" }],
      meta: { provenance: "curated", confidence: 0.92, curated_article_id: "a1" },
    });

    await knowledgeHybridSearch({ query: "refund policy", limit: 5, offset: 0, match: "any" });

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(options.method, "POST");
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
    assert.equal(new URL(url).pathname, "/api/v1/knowledge/hybrid_search");
    const sent = JSON.parse(options.body);
    assert.equal(sent.query, "refund policy");
    assert.equal(sent.limit, 5);
    assert.equal(sent.offset, 0);
    assert.equal(sent.match, "any");
  });

  test("preserves provenance=curated verbatim at the MCP boundary (AC-31.4.3)", async () => {
    setupEnv();
    mockFetch({
      data: [{ id: "a1", title: "Refund Policy" }],
      meta: { provenance: "curated", confidence: 0.92, curated_article_id: "a1" },
    });

    const result = await knowledgeHybridSearch({ query: "refund policy" });
    const parsed = JSON.parse(result.content[0].text);

    assert.equal(parsed.meta.provenance, "curated");
    assert.equal(parsed.meta.curated_article_id, "a1");
    assert.equal(parsed.data[0].id, "a1");
    assert.equal(result.isError, undefined);
  });

  test("preserves provenance=retrieved verbatim at the MCP boundary (AC-31.4.3)", async () => {
    setupEnv();
    mockFetch({
      data: [{ id: "b7", title: "Some Match" }],
      meta: { provenance: "retrieved", confidence: 0.41, curated_article_id: null },
    });

    const result = await knowledgeHybridSearch({ query: "onboarding" });
    const parsed = JSON.parse(result.content[0].text);

    assert.equal(parsed.meta.provenance, "retrieved");
    assert.equal(parsed.meta.curated_article_id, null);
  });

  test("omits optional fields from the body when not supplied", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: { provenance: "retrieved" } });

    await knowledgeHybridSearch({ query: "x" });

    const sent = JSON.parse(calls[0].options.body);
    assert.deepEqual(Object.keys(sent), ["query"]);
  });

  test("surfaces the missing-embedding-key remediation as the leading content block (keyword-only fallback)", async () => {
    setupEnv();
    // The combined pool degraded to keyword-only: 200 with a meta.remediation the
    // hybrid tool must surface PROMINENTLY (same contract as knowledge_search).
    mockFetch({
      data: [{ id: "b7", title: "Some Match" }],
      meta: {
        provenance: "retrieved",
        curated_article_id: null,
        search_mode: "keyword_only",
        fallback: true,
        fallback_reason: "no_embedding_key",
        remediation: {
          action: "configure_llm",
          missing: ["embedding"],
          message: "Semantic ranking is disabled.",
          mcp_tool: "set_llm_config",
          example: "set_llm_config({ ... })",
          api: "POST /api/v1/llm-config",
          docs: "https://loopctl.com/docs/byo-llm",
        },
      },
    });

    const result = await knowledgeHybridSearch({ query: "refund policy" });

    // The remediation rides in FRONT of the JSON payload — a regression that
    // dropped withRemediationNotice (back to toContent) would fail here.
    assert.match(result.content[0].text, /ACTION REQUIRED/);
    assert.match(result.content[0].text, /set_llm_config/);
    // The original payload is preserved as a following content block.
    const parsed = JSON.parse(result.content[result.content.length - 1].text);
    assert.equal(parsed.meta.provenance, "retrieved");
    assert.equal(parsed.meta.fallback_reason, "no_embedding_key");
  });
});

describe("US-31.4: knowledge_progressive_index and knowledge_progressive_drill", () => {
  test("index GETs progressive_index with the topic and returns capped stubs", async () => {
    setupEnv();
    const calls = mockFetch({
      data: [
        { id: "s1", title: "Stub 1", category: "reference", summary: "..." },
        { id: "s2", title: "Stub 2", category: "pattern", summary: "..." },
      ],
      meta: { top_k: 3, candidate_count: 6, truncated: true },
    });

    const result = await knowledgeProgressiveIndex({ topic: "refunds", limit: 3 });

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(options.method, "GET");
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
    const parsed = new URL(url);
    assert.equal(parsed.pathname, "/api/v1/knowledge/progressive_index");
    assert.equal(parsed.searchParams.get("topic"), "refunds");
    assert.equal(parsed.searchParams.get("limit"), "3");

    const out = JSON.parse(result.content[0].text);
    assert.equal(out.meta.truncated, true);
    assert.equal(out.data.length, 2);
    // Stubs carry no body.
    assert.equal(out.data[0].body, undefined);
  });

  test("drill GETs progressive/:id and returns the full article body", async () => {
    setupEnv();
    const calls = mockFetch({ data: { id: "s1", title: "Stub 1", body: "full body here" } });

    const result = await knowledgeProgressiveDrill({ article_id: "s1" });

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(options.method, "GET");
    assert.equal(new URL(url).pathname, "/api/v1/knowledge/progressive/s1");

    const out = JSON.parse(result.content[0].text);
    assert.equal(out.data.body, "full body here");
  });
});

describe("US-31.4: ListTools — new tools present, existing knowledge tools unchanged", () => {
  const indexPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "index.js");
  const indexSource = readFileSync(indexPath, "utf8");

  test("the three new tools are registered (def + dispatch case)", () => {
    for (const name of [
      "knowledge_hybrid_search",
      "knowledge_progressive_index",
      "knowledge_progressive_drill",
    ]) {
      assert.ok(indexSource.includes(`name: "${name}"`), `${name} tool definition present`);
      assert.ok(indexSource.includes(`case "${name}":`), `${name} dispatch case present`);
    }
  });

  test("existing knowledge tools remain registered (additive, unchanged surface)", () => {
    for (const name of ["knowledge_search", "knowledge_get", "knowledge_context", "knowledge_list"]) {
      assert.ok(indexSource.includes(`name: "${name}"`), `${name} still present`);
      assert.ok(indexSource.includes(`case "${name}":`), `${name} dispatch still present`);
    }
  });

  test("hybrid_search docstring explains provenance and when to prefer it over knowledge_search", () => {
    // Locate the hybrid tool's description block.
    const idx = indexSource.indexOf('name: "knowledge_hybrid_search"');
    assert.ok(idx > 0);
    const block = indexSource.slice(idx, idx + 2000);
    assert.ok(/curated/i.test(block), "mentions curated provenance");
    assert.ok(/retrieved/i.test(block), "mentions retrieved provenance");
    assert.ok(/knowledge_search/.test(block), "explains preference vs knowledge_search");
  });
});
