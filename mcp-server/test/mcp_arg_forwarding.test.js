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
  llmUsagePath,
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
// #411 gap1: resolve_project (cheap repo -> project_id resolution)
// ---------------------------------------------------------------------------

describe("#411 gap1: resolve_project wiring", () => {
  test("TOOLS declares a resolve_project tool", () => {
    assert.match(INDEX_SRC, /name: "resolve_project",/, 'must declare a "resolve_project" tool');
  });

  test("resolveProject GETs /projects/resolve with slug/repo_url/name on the agent key", () => {
    assert.match(
      INDEX_SRC,
      /async function resolveProject\(\{ slug, repo_url, name \} = \{\}\) \{[\s\S]*?\/api\/v1\/projects\/resolve\?\$\{params\}[\s\S]*?LOOPCTL_AGENT_KEY/,
      "resolveProject must GET /api/v1/projects/resolve with a query string on the agent key",
    );
    assert.match(INDEX_SRC, /if \(slug\) params\.set\("slug", slug\);/);
    assert.match(INDEX_SRC, /if \(repo_url\) params\.set\("repo_url", repo_url\);/);
    assert.match(INDEX_SRC, /if \(name\) params\.set\("name", name\);/);
  });

  test("the resolve_project dispatch case calls resolveProject(args)", () => {
    assert.match(
      INDEX_SRC,
      /case "resolve_project":\s*\n\s*return await resolveProject\(args\);/,
      "the resolve_project dispatch case must call resolveProject(args)",
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
// US-26.7.1: public agent-rooted self-signup tool
// ---------------------------------------------------------------------------

describe("US-26.7.1: signup tool (agent-rooted, KB-tier self-signup)", () => {
  test("TOOLS declares a signup tool requiring name/slug/email", () => {
    assert.match(INDEX_SRC, /name: "signup",/, "TOOLS must declare a \"signup\" tool");
    assert.match(
      INDEX_SRC,
      /required: \["name", "slug", "email"\],/,
      "the signup tool must require name, slug, and email",
    );
  });

  test("signup() calls publicApiCall (no API key) against POST /api/v1/signup", () => {
    assert.match(
      INDEX_SRC,
      /async function signup\(\{ name, slug, email \}\) \{[\s\S]*?publicApiCall\(\s*"POST",\s*"\/api\/v1\/signup"/,
      "signup() must delegate to publicApiCall (not apiCall — no key exists yet) against POST /api/v1/signup",
    );
  });

  test("the signup dispatch case calls signup(args)", () => {
    assert.match(
      INDEX_SRC,
      /case "signup":\s*\n\s*return await signup\(args\);/,
      "the signup dispatch case must call signup(args)",
    );
  });

  test("publicApiCall never attaches an Authorization header", () => {
    const match = INDEX_SRC.match(
      /async function publicApiCall\(method, path, body\) \{[\s\S]*?\n}\n/,
    );
    assert.ok(match, "publicApiCall must be defined");
    assert.doesNotMatch(match[0], /Authorization/, "publicApiCall must not send an Authorization header");
  });
});

// ---------------------------------------------------------------------------
// Epic 28 (#179): per-tenant BYO LLM config + usage tools
// ---------------------------------------------------------------------------

describe("#179 BYO LLM: knowledge_llm_usage pagination (real llmUsagePath)", () => {
  test("forwards from, to, limit, and offset", () => {
    const url = new URL(
      `https://x${llmUsagePath({ from: "2026-01-01T00:00:00Z", to: "2026-02-01T00:00:00Z", limit: 10, offset: 20 })}`,
    );
    assert.equal(url.pathname, "/api/v1/knowledge/llm-usage");
    assert.equal(url.searchParams.get("from"), "2026-01-01T00:00:00Z");
    assert.equal(url.searchParams.get("to"), "2026-02-01T00:00:00Z");
    assert.equal(url.searchParams.get("limit"), "10");
    assert.equal(url.searchParams.get("offset"), "20");
  });

  test("omits params when none are supplied", () => {
    assert.equal(llmUsagePath(), "/api/v1/knowledge/llm-usage");
    assert.equal(llmUsagePath({}), "/api/v1/knowledge/llm-usage");
  });

  test("index.js knowledgeLlmUsage uses llmUsagePath(args) + orch key, dispatch passes args", () => {
    assert.match(
      INDEX_SRC,
      /async function knowledgeLlmUsage\(args = \{\}\) \{[\s\S]*?llmUsagePath\(args\)[\s\S]*?LOOPCTL_ORCH_KEY/,
      "knowledgeLlmUsage must delegate to llmUsagePath(args) on the orch key",
    );
    assert.match(
      INDEX_SRC,
      /case "knowledge_llm_usage":\s*\n\s*return await knowledgeLlmUsage\(args\);/,
      "the knowledge_llm_usage dispatch case must call knowledgeLlmUsage(args)",
    );
  });
});

describe("#179 BYO LLM: llm_config / set_llm_config use the USER key", () => {
  test("llm_config GETs the config with the EXACT user key (review #12)", () => {
    assert.match(
      INDEX_SRC,
      /async function llmConfig\(\) \{[\s\S]*?"\/api\/v1\/tenants\/me\/llm-config"[\s\S]*?LOOPCTL_USER_KEY[\s\S]*?exactKey: true/,
      "llmConfig must GET /tenants/me/llm-config with the EXACT user key (exactKey:true)",
    );
    assert.match(
      INDEX_SRC,
      /case "llm_config":\s*\n\s*return await llmConfig\(\);/,
      "the llm_config dispatch case must call llmConfig()",
    );
  });

  test("set_llm_config PATCHes with the EXACT user key (review #12, #13)", () => {
    assert.match(
      INDEX_SRC,
      /async function setLlmConfig\(\{[\s\S]*?"PATCH",\s*\n\s*"\/api\/v1\/tenants\/me\/llm-config",[\s\S]*?LOOPCTL_USER_KEY[\s\S]*?exactKey: true/,
      "setLlmConfig must PATCH /tenants/me/llm-config with the EXACT user key (exactKey:true)",
    );
    assert.match(
      INDEX_SRC,
      /case "set_llm_config":\s*\n\s*return await setLlmConfig\(args\);/,
      "the set_llm_config dispatch case must call setLlmConfig(args)",
    );
  });

  test("apiCall exactKey mode bypasses the global LOOPCTL_API_KEY override", () => {
    // exactKey:true must use the passed key verbatim (not resolveKey), so a secret
    // op never runs under a non-user global override (review #12).
    assert.match(
      INDEX_SRC,
      /const key = exactKey \? keyOverride : resolveKey\(keyOverride\);/,
      "apiCall must use the exact key (not resolveKey) when exactKey is true",
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
