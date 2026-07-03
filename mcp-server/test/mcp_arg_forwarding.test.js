/**
 * Regression tests for the MCP server arg-forwarding + apiCall robustness fixes:
 *
 *   - #247 (mcp-01): list_projects must forward page/page_size (dispatch dropped args).
 *   - #248 (mcp-02): knowledge_ingestion_jobs must forward limit/offset/since_days.
 *   - #249 (mcp-03): apiCall must not throw on an empty/invalid JSON body when the
 *     response carries a JSON content-type — it returns a STRUCTURED error instead.
 *
 * Uses the Node.js built-in test runner (node:test). Run: node --test test/
 *
 * The handler functions and the dispatch switch in index.js are not exported
 * (server entry point with top-level await). We (a) mirror the exact handler +
 * apiCall bodies here and drive them through a mocked fetch, and (b) assert the
 * source dispatch cases pass `args` through, so the real bug (dropped args) can
 * never silently regress.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

// ---------------------------------------------------------------------------
// Minimal mirror of index.js helpers under test
// ---------------------------------------------------------------------------

function getBaseUrl() {
  return (process.env.LOOPCTL_SERVER || "https://loopctl.com").replace(/\/$/, "");
}

function resolveKey(keyOverride) {
  return process.env.LOOPCTL_API_KEY || keyOverride || process.env.LOOPCTL_ORCH_KEY;
}

// Mirrors index.js apiCall including the #249 defensive JSON parse.
async function apiCall(method, reqPath, body, keyOverride) {
  const url = `${getBaseUrl()}${reqPath}`;
  const key = resolveKey(keyOverride);

  if (!key) {
    return { error: true, status: 0, body: "No API key configured." };
  }

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

  if (response.status === 204) {
    return { ok: true };
  }

  let responseBody;
  const contentType = response.headers.get("content-type") || "";
  if (contentType.includes("application/json")) {
    const raw = await response.text();
    if (raw.trim() === "") {
      return {
        error: true,
        status: response.status,
        body: `invalid/empty JSON response from server (HTTP ${response.status}): empty body`,
      };
    }
    try {
      responseBody = JSON.parse(raw);
    } catch {
      const snippet = raw.length > 200 ? `${raw.slice(0, 200)}... (truncated)` : raw;
      return {
        error: true,
        status: response.status,
        body: `invalid/empty JSON response from server (HTTP ${response.status}): ${snippet}`,
      };
    }
  } else {
    const text = await response.text();
    try {
      responseBody = JSON.parse(text);
    } catch {
      responseBody = text;
    }
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

// Mirrors index.js listProjects.
async function listProjects({ page, page_size } = {}) {
  const params = new URLSearchParams();
  if (page != null) params.set("page", String(page));
  if (page_size != null) params.set("page_size", String(page_size));
  const query = params.toString() ? `?${params}` : "";
  const result = await apiCall("GET", `/api/v1/projects${query}`);
  return toContent(result);
}

// Mirrors index.js knowledgeIngestionJobs.
async function knowledgeIngestionJobs({ limit, offset, since_days } = {}) {
  const params = new URLSearchParams();
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  if (since_days != null) params.set("since_days", String(since_days));
  const query = params.toString() ? `?${params}` : "";
  const result = await apiCall(
    "GET",
    `/api/v1/knowledge/ingestion-jobs${query}`,
    null,
    process.env.LOOPCTL_ORCH_KEY,
  );
  return toContent(result);
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const ORCH_KEY = "lc_test_orch_key";
const BASE_URL = "https://loopctl.com";

function setupEnv() {
  process.env.LOOPCTL_SERVER = BASE_URL;
  process.env.LOOPCTL_ORCH_KEY = ORCH_KEY;
  delete process.env.LOOPCTL_API_KEY;
}

/** Mock fetch that always answers with a JSON content-type + canned JSON body. */
function mockFetch(responseBody = { data: [], meta: {} }, status = 200) {
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: (h) => (h.toLowerCase() === "content-type" ? "application/json" : null) },
      json: async () => responseBody,
      text: async () => JSON.stringify(responseBody),
    };
  };
  return calls;
}

/**
 * Mock fetch that returns a JSON content-type but a caller-controlled raw body
 * string, and a json() that reflects real JSON.parse semantics (throws on bad
 * input) — this is what a truncated/empty Fly edge response looks like.
 */
function mockFetchRaw(rawBody, status = 200, contentType = "application/json") {
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: (h) => (h.toLowerCase() === "content-type" ? contentType : null) },
      json: async () => JSON.parse(rawBody), // throws on empty/invalid, like the platform
      text: async () => rawBody,
    };
  };
  return calls;
}

const INDEX_SRC = readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "index.js"),
  "utf8",
);

// ---------------------------------------------------------------------------
// #247 (mcp-01): list_projects forwards page/page_size
// ---------------------------------------------------------------------------

describe("#247 mcp-01: list_projects pagination", () => {
  test("forwards page and page_size as query params", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: { page: 2 } });

    await listProjects({ page: 2, page_size: 50 });

    assert.equal(calls.length, 1);
    const url = new URL(calls[0].url);
    assert.equal(url.pathname, "/api/v1/projects");
    assert.equal(url.searchParams.get("page"), "2");
    assert.equal(url.searchParams.get("page_size"), "50");
  });

  test("omits pagination params when none are supplied", async () => {
    setupEnv();
    const calls = mockFetch();

    await listProjects();

    const url = new URL(calls[0].url);
    assert.equal(url.searchParams.has("page"), false);
    assert.equal(url.searchParams.has("page_size"), false);
    assert.equal(url.search, "");
  });

  test("dispatch passes args through (no dropped page/page_size)", () => {
    assert.match(
      INDEX_SRC,
      /case "list_projects":\s*\n\s*return await listProjects\(args\);/,
      "the list_projects dispatch case must call listProjects(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// #248 (mcp-02): knowledge_ingestion_jobs forwards limit/offset/since_days
// ---------------------------------------------------------------------------

describe("#248 mcp-02: knowledge_ingestion_jobs pagination", () => {
  test("forwards limit, offset, and since_days as query params", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: { limit: 10 } });

    await knowledgeIngestionJobs({ limit: 10, offset: 20, since_days: 7 });

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    const parsed = new URL(url);
    assert.equal(parsed.pathname, "/api/v1/knowledge/ingestion-jobs");
    assert.equal(parsed.searchParams.get("limit"), "10");
    assert.equal(parsed.searchParams.get("offset"), "20");
    assert.equal(parsed.searchParams.get("since_days"), "7");
    assert.equal(options.headers.Authorization, `Bearer ${ORCH_KEY}`);
  });

  test("omits params when none are supplied", async () => {
    setupEnv();
    const calls = mockFetch();

    await knowledgeIngestionJobs();

    const url = new URL(calls[0].url);
    assert.equal(url.search, "");
  });

  test("dispatch passes args through (no dropped limit/offset/since_days)", () => {
    assert.match(
      INDEX_SRC,
      /case "knowledge_ingestion_jobs":\s*\n\s*return await knowledgeIngestionJobs\(args\);/,
      "the knowledge_ingestion_jobs dispatch case must call knowledgeIngestionJobs(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// #249 (mcp-03): apiCall guards response.json()
// ---------------------------------------------------------------------------

describe("#249 mcp-03: apiCall defensive JSON parsing", () => {
  test("valid JSON body still parses normally", async () => {
    setupEnv();
    mockFetchRaw(JSON.stringify({ data: [1, 2, 3], meta: { total_count: 3 } }));

    const result = await apiCall("GET", "/api/v1/projects", null, ORCH_KEY);

    assert.equal(result.error, undefined, "valid JSON must not be treated as an error");
    assert.deepEqual(result.data, [1, 2, 3]);
  });

  test("empty body with JSON content-type returns a structured error (no throw)", async () => {
    setupEnv();
    mockFetchRaw("", 502);

    let result;
    await assert.doesNotReject(async () => {
      result = await apiCall("GET", "/api/v1/projects", null, ORCH_KEY);
    }, "an empty JSON body must not produce an unhandled throw");

    assert.equal(result.error, true);
    assert.equal(result.status, 502);
    assert.match(result.body, /empty body/);
    assert.match(result.body, /HTTP 502/);
  });

  test("invalid JSON body with JSON content-type returns a structured error (no throw)", async () => {
    setupEnv();
    mockFetchRaw("<html>502 Bad Gateway</html>", 503);

    let result;
    await assert.doesNotReject(async () => {
      result = await apiCall("GET", "/api/v1/projects", null, ORCH_KEY);
    }, "malformed JSON must not produce an unhandled throw");

    assert.equal(result.error, true);
    assert.equal(result.status, 503);
    assert.match(result.body, /invalid\/empty JSON response from server/);
    assert.match(result.body, /HTTP 503/);
    // A snippet of the raw body is included for debugging.
    assert.match(result.body, /502 Bad Gateway/);
  });

  test("long invalid JSON body is truncated in the error snippet", async () => {
    setupEnv();
    const long = "x".repeat(1000);
    mockFetchRaw(long, 500);

    const result = await apiCall("GET", "/api/v1/projects", null, ORCH_KEY);

    assert.equal(result.error, true);
    assert.match(result.body, /\.\.\. \(truncated\)/);
    assert.ok(result.body.length < long.length, "snippet must be shorter than the raw body");
  });

  test("source: apiCall no longer calls response.json() directly", () => {
    // The unguarded `await response.json()` was the crash vector; it must be gone.
    assert.ok(
      !/responseBody = await response\.json\(\);/.test(INDEX_SRC),
      "index.js must not call response.json() unguarded",
    );
  });
});
