/**
 * Regression tests for the MCP server arg-forwarding + apiCall robustness fixes:
 *
 *   - #247 (mcp-01): list_projects must forward page/page_size (dispatch dropped args).
 *   - #248 (mcp-02): knowledge_ingestion_jobs must forward limit/offset/since_days.
 *   - #249 (mcp-03): apiCall must not throw on an empty/invalid JSON body when the
 *     response carries a JSON content-type — it returns a STRUCTURED error instead.
 *
 * Uses the Node.js built-in test runner (node:test). Run: node --test test/*.test.js
 *
 * SINGLE SOURCE OF TRUTH: the query-building and JSON-parse logic that had bugs
 * lives in ../lib/http-helpers.js, imported by BOTH the real server (index.js) and
 * these tests. So the behavioral tests below exercise the exact code the server
 * ships — a regression in projectsPath / ingestionJobsPath / parseJsonResponseBody
 * fails here. The remaining tests pin the WIRING in index.js (that the handlers and
 * apiCall actually call the shared helpers, and the dispatch passes args through),
 * so drift in either the logic or its use fails CI.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  buildQuery,
  projectsPath,
  ingestionJobsPath,
  parseJsonResponseBody,
} from "../lib/http-helpers.js";

const INDEX_SRC = readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "index.js"),
  "utf8",
);

// ---------------------------------------------------------------------------
// buildQuery — the shared primitive
// ---------------------------------------------------------------------------

describe("buildQuery (shared query-string primitive)", () => {
  test("emits set pairs and skips null/undefined", () => {
    assert.equal(buildQuery([["a", 1], ["b", undefined], ["c", null], ["d", 0]]), "?a=1&d=0");
  });

  test("returns empty string when nothing is set", () => {
    assert.equal(buildQuery([["a", undefined], ["b", null]]), "");
  });
});

// ---------------------------------------------------------------------------
// #247 (mcp-01): list_projects forwards page/page_size (REAL projectsPath)
// ---------------------------------------------------------------------------

describe("#247 mcp-01: list_projects pagination (real projectsPath)", () => {
  test("forwards page and page_size", () => {
    const url = new URL(`https://x${projectsPath({ page: 2, page_size: 50 })}`);
    assert.equal(url.pathname, "/api/v1/projects");
    assert.equal(url.searchParams.get("page"), "2");
    assert.equal(url.searchParams.get("page_size"), "50");
  });

  test("forwards page alone", () => {
    assert.equal(projectsPath({ page: 3 }), "/api/v1/projects?page=3");
  });

  test("omits pagination params when none are supplied", () => {
    assert.equal(projectsPath(), "/api/v1/projects");
    assert.equal(projectsPath({}), "/api/v1/projects");
  });

  test("index.js listProjects uses projectsPath(args) and passes args from dispatch", () => {
    assert.match(
      INDEX_SRC,
      /async function listProjects\(args = \{\}\) \{[\s\S]*?projectsPath\(args\)/,
      "listProjects must delegate to the shared projectsPath(args)",
    );
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

describe("#248 mcp-02: knowledge_ingestion_jobs pagination (real ingestionJobsPath)", () => {
  test("forwards limit, offset, and since_days", () => {
    const url = new URL(`https://x${ingestionJobsPath({ limit: 10, offset: 20, since_days: 7 })}`);
    assert.equal(url.pathname, "/api/v1/knowledge/ingestion-jobs");
    assert.equal(url.searchParams.get("limit"), "10");
    assert.equal(url.searchParams.get("offset"), "20");
    assert.equal(url.searchParams.get("since_days"), "7");
  });

  test("omits params when none are supplied", () => {
    assert.equal(ingestionJobsPath(), "/api/v1/knowledge/ingestion-jobs");
    assert.equal(ingestionJobsPath({}), "/api/v1/knowledge/ingestion-jobs");
  });

  test("index.js knowledgeIngestionJobs uses ingestionJobsPath(args) + orch key, dispatch passes args", () => {
    assert.match(
      INDEX_SRC,
      /async function knowledgeIngestionJobs\(args = \{\}\) \{[\s\S]*?ingestionJobsPath\(args\)[\s\S]*?LOOPCTL_ORCH_KEY/,
      "knowledgeIngestionJobs must delegate to ingestionJobsPath(args) on the orch key",
    );
    assert.match(
      INDEX_SRC,
      /case "knowledge_ingestion_jobs":\s*\n\s*return await knowledgeIngestionJobs\(args\);/,
      "the knowledge_ingestion_jobs dispatch case must call knowledgeIngestionJobs(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// #249 (mcp-03): defensive JSON parsing (REAL parseJsonResponseBody)
// ---------------------------------------------------------------------------

describe("#249 mcp-03: parseJsonResponseBody (shared with apiCall)", () => {
  test("valid JSON returns { parsed } (no error)", () => {
    const out = parseJsonResponseBody(
      JSON.stringify({ data: [1, 2, 3], meta: { total_count: 3 } }),
      200,
    );
    assert.equal(out.error, undefined);
    assert.deepEqual(out.parsed, { data: [1, 2, 3], meta: { total_count: 3 } });
  });

  test("empty body returns a structured error with the status (no throw)", () => {
    let out;
    assert.doesNotThrow(() => {
      out = parseJsonResponseBody("", 502);
    });
    assert.equal(out.error, true);
    assert.equal(out.status, 502);
    assert.match(out.body, /empty body/);
    assert.match(out.body, /HTTP 502/);
  });

  test("whitespace-only body is treated as empty", () => {
    const out = parseJsonResponseBody("   \n\t ", 503);
    assert.equal(out.error, true);
    assert.match(out.body, /empty body/);
  });

  test("invalid JSON returns a structured error with a raw-body snippet (no throw)", () => {
    let out;
    assert.doesNotThrow(() => {
      out = parseJsonResponseBody("<html>502 Bad Gateway</html>", 503);
    });
    assert.equal(out.error, true);
    assert.equal(out.status, 503);
    assert.match(out.body, /invalid\/empty JSON response from server/);
    assert.match(out.body, /HTTP 503/);
    assert.match(out.body, /502 Bad Gateway/);
  });

  test("long invalid body is truncated in the snippet", () => {
    const long = "x".repeat(1000);
    const out = parseJsonResponseBody(long, 500);
    assert.equal(out.error, true);
    assert.match(out.body, /\.\.\. \(truncated\)/);
    assert.ok(out.body.length < long.length, "snippet must be shorter than the raw body");
  });

  test("index.js apiCall delegates to parseJsonResponseBody and no longer calls response.json() unguarded", () => {
    assert.match(
      INDEX_SRC,
      /parseJsonResponseBody\(raw, response\.status\)/,
      "apiCall must parse the JSON branch via the shared parseJsonResponseBody",
    );
    assert.ok(
      !/responseBody = await response\.json\(\);/.test(INDEX_SRC),
      "index.js must not call response.json() unguarded",
    );
  });
});
