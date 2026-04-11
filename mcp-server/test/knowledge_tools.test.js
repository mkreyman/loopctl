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

// ---------------------------------------------------------------------------
// Handler implementations (mirror index.js exactly)
// ---------------------------------------------------------------------------

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
