/**
 * Tests for US-28.4: MCP memory_* tools (remember/recall/forget/list) with
 * memory-vs-knowledge docstrings.
 *
 * Uses Node.js built-in test runner (node:test). Run: node --test test/
 *
 * Strategy (mirrors knowledge_tools.test.js / story_tools.test.js / mcp_arg_
 * forwarding.test.js): index.js is a stdio entry point with top-level await, so
 * its handlers cannot be imported directly. We combine:
 *
 *   - Source-assertion tests: read index.js as text and assert the four TOOLS
 *     entries exist with disambiguating descriptions, a switch case each, and
 *     that the handlers route through apiCall (the shared witness-aware HTTP
 *     helper) to the correct /api/v1/memory* path + method (AC-28.4.1,
 *     AC-28.4.3, AC-28.4.5).
 *   - Behavioral tests: a minimal reimplementation of the handler bodies
 *     (mirroring index.js exactly) exercised against a mocked fetch, covering
 *     the remember->recall happy path (TC-28.4.1), an auth/witness failure
 *     (TC-28.4.4), and that recall/list meta (fallback/total_count) is
 *     surfaced (AC-28.4.4).
 *   - Scope isolation (TC-28.4.3 / AC-28.4.5): the memory tool inputSchemas
 *     must NOT accept tenant_id/subject_id, and handlers must never forward a
 *     body-supplied scope — the tool cannot even express a cross-scope read;
 *     scope is key-derived server-side (US-28.3's job to enforce there).
 *
 * The transparent-412-witness-retry mechanics are already covered end-to-end
 * against createWitnessClient in witness_sth.test.js; here we only need to
 * confirm the memory handlers go through apiCall (not a raw fetch), which the
 * source-assertion tests below do.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const INDEX_SRC = readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "index.js"),
  "utf8",
);

// ---------------------------------------------------------------------------
// Minimal re-implementation of the shared helpers (mirrors index.js logic)
// ---------------------------------------------------------------------------

function getBaseUrl() {
  return (process.env.LOOPCTL_SERVER || "https://loopctl.com").replace(/\/$/, "");
}

function resolveKey(keyOverride) {
  return process.env.LOOPCTL_API_KEY || keyOverride || process.env.LOOPCTL_ORCH_KEY;
}

async function apiCall(method, apiPath, body, keyOverride) {
  const url = `${getBaseUrl()}${apiPath}`;
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
// Handler implementations (mirror index.js exactly — see the "Agent Memory
// Tools (US-28.4)" section)
// ---------------------------------------------------------------------------

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

  const result = await apiCall("POST", "/api/v1/memory", payload, process.env.LOOPCTL_AGENT_KEY);
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
  return toContent(result);
}

async function memoryList({ limit, offset, include_superseded, all_subjects }) {
  const params = new URLSearchParams();
  if (limit != null) params.set("limit", String(limit));
  if (offset != null) params.set("offset", String(offset));
  if (include_superseded != null) params.set("include_superseded", String(include_superseded));
  if (all_subjects != null) params.set("all_subjects", String(all_subjects));

  const qs = params.toString();
  const path = qs ? `/api/v1/memory?${qs}` : "/api/v1/memory";
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

async function memoryForget({ id }) {
  const result = await apiCall(
    "DELETE",
    `/api/v1/memory/${id}`,
    null,
    process.env.LOOPCTL_AGENT_KEY,
  );
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
// TC-28.4.1: remember -> recall happy-path round trip
// ---------------------------------------------------------------------------

describe("TC-28.4.1: memory_remember -> memory_recall happy path", () => {
  test("memory_remember POSTs to /api/v1/memory with the agent key and returns the stored memory", async () => {
    setupEnv();
    const memory = {
      id: "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0",
      tier: "long_term",
      text: "prefers Req over Tesla",
    };
    const calls = mockFetch({ data: memory }, 201);

    const result = await memoryRemember({ tier: "long_term", text: "prefers Req over Tesla" });

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(new URL(url).pathname, "/api/v1/memory");
    assert.equal(options.method, "POST");
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
    assert.deepEqual(JSON.parse(options.body), {
      tier: "long_term",
      text: "prefers Req over Tesla",
    });
    assert.equal(result.isError, undefined);
    assert.deepEqual(JSON.parse(result.content[0].text), { data: memory });
  });

  test("memory_recall POSTs the query to /api/v1/memory/recall and returns data + meta", async () => {
    setupEnv();
    const recallResponse = {
      data: [{ memory: { id: "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0", text: "prefers Req" }, score: 0.92 }],
      meta: { total_count: 1, fallback: false, reason: null, underfilled: false },
    };
    const calls = mockFetch(recallResponse, 200);

    const result = await memoryRecall({ query: "HTTP client preference" });

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(new URL(url).pathname, "/api/v1/memory/recall");
    assert.equal(options.method, "POST");
    assert.deepEqual(JSON.parse(options.body), { query: "HTTP client preference" });
    assert.equal(result.isError, undefined);

    const parsed = JSON.parse(result.content[0].text);
    assert.deepEqual(parsed, recallResponse);
    assert.equal(parsed.data[0].memory.id, "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0");
  });
});

// ---------------------------------------------------------------------------
// AC-28.4.4: recall/list surface meta (fallback flag/reason, total_count)
// ---------------------------------------------------------------------------

describe("AC-28.4.4: memory_recall surfaces degraded-recall meta", () => {
  test("meta.fallback/meta.reason are preserved verbatim so the caller can tell degraded recall from an empty scope", async () => {
    setupEnv();
    const degraded = {
      data: [],
      meta: { total_count: 0, fallback: true, reason: "no_embedding_key", underfilled: false },
    };
    mockFetch(degraded, 200);

    const result = await memoryRecall({ query: "anything" });
    const parsed = JSON.parse(result.content[0].text);

    assert.equal(parsed.meta.fallback, true);
    assert.equal(parsed.meta.reason, "no_embedding_key");
    assert.equal(parsed.meta.total_count, 0);
  });
});

describe("AC-28.4.4: memory_list surfaces total_count/limit/offset meta", () => {
  test("meta is preserved verbatim so an empty page is distinguishable from a short one", async () => {
    setupEnv();
    const listResponse = {
      data: [],
      meta: { total_count: 0, limit: 50, offset: 0 },
    };
    const calls = mockFetch(listResponse, 200);

    const result = await memoryList({});

    assert.equal(calls.length, 1);
    assert.equal(new URL(calls[0].url).pathname, "/api/v1/memory");
    assert.equal(calls[0].options.method, "GET");

    const parsed = JSON.parse(result.content[0].text);
    assert.deepEqual(parsed.meta, { total_count: 0, limit: 50, offset: 0 });
  });

  test("forwards limit/offset/include_superseded/all_subjects as query params", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: { total_count: 0, limit: 10, offset: 5 } });

    await memoryList({ limit: 10, offset: 5, include_superseded: true, all_subjects: true });

    const parsedUrl = new URL(calls[0].url);
    assert.equal(parsedUrl.searchParams.get("limit"), "10");
    assert.equal(parsedUrl.searchParams.get("offset"), "5");
    assert.equal(parsedUrl.searchParams.get("include_superseded"), "true");
    assert.equal(parsedUrl.searchParams.get("all_subjects"), "true");
  });
});

// ---------------------------------------------------------------------------
// TC-28.4.4: auth/witness failure surfaces a structured error
// ---------------------------------------------------------------------------

describe("TC-28.4.4: auth/witness failure returns a structured error, not a throw", () => {
  test("a 401 (missing/invalid key) from memory_remember returns {error:true, status:401}", async () => {
    setupEnv();
    mockFetch({ error: { status: 401, code: "unauthorized", message: "invalid key" } }, 401);

    const result = await memoryRemember({ tier: "long_term", text: "x" });

    assert.equal(result.isError, true);
    const parsed = JSON.parse(result.content[0].text);
    assert.equal(parsed.error, true);
    assert.equal(parsed.status, 401);
  });

  test("a 412 witness_bootstrap_already_consumed from memory_recall returns {error:true, status:412}", async () => {
    setupEnv();
    mockFetch(
      { error: { status: 412, code: "witness_bootstrap_already_consumed" } },
      412,
    );

    const result = await memoryRecall({ query: "x" });

    assert.equal(result.isError, true);
    const parsed = JSON.parse(result.content[0].text);
    assert.equal(parsed.status, 412);
  });

  test("a 404 from memory_forget (unknown/foreign-scope id) returns {error:true, status:404} — no existence leak", async () => {
    setupEnv();
    mockFetch({ error: { status: 404, code: "not_found" } }, 404);

    const result = await memoryForget({ id: "00000000-0000-0000-0000-000000000000" });

    assert.equal(result.isError, true);
    const parsed = JSON.parse(result.content[0].text);
    assert.equal(parsed.status, 404);
  });
});

describe("memory_forget: happy path", () => {
  test("DELETEs /api/v1/memory/:id with the agent key", async () => {
    setupEnv();
    const id = "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0";
    const calls = mockFetch({ data: { id, deleted: true } }, 200);

    const result = await memoryForget({ id });

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(new URL(url).pathname, `/api/v1/memory/${id}`);
    assert.equal(options.method, "DELETE");
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
    assert.equal(result.isError, undefined);
  });
});

// ---------------------------------------------------------------------------
// TC-28.4.3 / AC-28.4.5: scope isolation — the tool cannot even express a
// cross-scope read/write. Scope is key-derived server-side (US-28.3's job);
// here we assert the MCP layer provides no bypass surface.
// ---------------------------------------------------------------------------

describe("TC-28.4.3: scope isolation — no tenant_id/subject_id bypass surface", () => {
  test("none of the four memory tool inputSchemas accept tenant_id or subject_id", () => {
    for (const toolName of ["memory_remember", "memory_recall", "memory_list", "memory_forget"]) {
      const toolStart = INDEX_SRC.indexOf(`name: "${toolName}",`);
      assert.ok(toolStart !== -1, `${toolName} TOOLS entry must exist`);

      // Slice to the next "name: " that starts a sibling tool entry (or a
      // generous bound), then narrow further to JUST the inputSchema block —
      // the free-text `description` legitimately explains that scope is
      // resolved from tenant_id/subject_id server-side, so only the schema's
      // `properties` (the actual bypass surface an agent could fill in)
      // must be free of those keys.
      const nextEntry = INDEX_SRC.indexOf('\n    name: "', toolStart + 20);
      const entryEnd = nextEntry === -1 ? toolStart + 4000 : nextEntry;
      const inputSchemaStart = INDEX_SRC.indexOf("inputSchema:", toolStart);
      assert.ok(
        inputSchemaStart !== -1 && inputSchemaStart < entryEnd,
        `${toolName} must have an inputSchema`,
      );
      const schemaBlock = INDEX_SRC.slice(inputSchemaStart, entryEnd);

      assert.ok(
        !/\btenant_id\b/.test(schemaBlock),
        `${toolName} inputSchema must not expose a tenant_id property`,
      );
      assert.ok(
        !/\bsubject_id\b/.test(schemaBlock),
        `${toolName} inputSchema must not expose a subject_id property`,
      );
    }
  });

  test("handlers never forward a body-supplied tenant_id/subject_id/scope to apiCall", () => {
    for (const fnName of ["memoryRemember", "memoryRecall", "memoryList", "memoryForget"]) {
      const start = INDEX_SRC.indexOf(`async function ${fnName}(`);
      assert.ok(start !== -1, `${fnName} handler must exist`);
      const end = INDEX_SRC.indexOf("\n}\n", start);
      const body = INDEX_SRC.slice(start, end);

      assert.ok(!/tenant_id/.test(body), `${fnName} must not reference tenant_id`);
      assert.ok(!/subject_id/.test(body), `${fnName} must not reference subject_id`);
    }
  });

  test("memoryRemember/memoryRecall/memoryList/memoryForget only ever call apiCall (never a raw fetch)", () => {
    for (const fnName of ["memoryRemember", "memoryRecall", "memoryList", "memoryForget"]) {
      const start = INDEX_SRC.indexOf(`async function ${fnName}(`);
      assert.ok(start !== -1, `${fnName} handler must exist`);
      const end = INDEX_SRC.indexOf("\n}\n", start);
      const body = INDEX_SRC.slice(start, end);

      assert.ok(/apiCall\(/.test(body), `${fnName} must call apiCall(...) — inherits witness/STH`);
      assert.ok(!/(?<!api)fetch\(/i.test(body), `${fnName} must not call a raw fetch`);
    }
  });
});

// ---------------------------------------------------------------------------
// AC-28.4.1 / AC-28.4.2 / AC-28.4.5: source-level wiring assertions
// ---------------------------------------------------------------------------

describe("AC-28.4.1: four memory tools registered by the existing convention", () => {
  test("TOOLS array has an entry for each of the four tools", () => {
    for (const toolName of ["memory_remember", "memory_recall", "memory_list", "memory_forget"]) {
      assert.ok(
        INDEX_SRC.includes(`name: "${toolName}",`),
        `TOOLS array must have an entry named "${toolName}"`,
      );
    }
  });

  test("CallToolRequestSchema switch has a case for each of the four tools", () => {
    assert.match(INDEX_SRC, /case "memory_remember":\s*\n\s*return await memoryRemember\(args\);/);
    assert.match(INDEX_SRC, /case "memory_recall":\s*\n\s*return await memoryRecall\(args\);/);
    assert.match(INDEX_SRC, /case "memory_list":\s*\n\s*return await memoryList\(args\);/);
    assert.match(INDEX_SRC, /case "memory_forget":\s*\n\s*return await memoryForget\(args\);/);
  });

  test("each handler calls the matching /api/v1/memory* endpoint via apiCall", () => {
    const rememberStart = INDEX_SRC.indexOf("async function memoryRemember(");
    const rememberBody = INDEX_SRC.slice(rememberStart, rememberStart + 1200);
    assert.match(rememberBody, /apiCall\(\s*"POST",\s*"\/api\/v1\/memory",/);

    const recallStart = INDEX_SRC.indexOf("async function memoryRecall(");
    const recallBody = INDEX_SRC.slice(recallStart, recallStart + 700);
    assert.match(recallBody, /apiCall\(\s*"POST",\s*"\/api\/v1\/memory\/recall",/);

    const listStart = INDEX_SRC.indexOf("async function memoryList(");
    const listBody = INDEX_SRC.slice(listStart, listStart + 900);
    assert.match(listBody, /apiCall\("GET", path, null, process\.env\.LOOPCTL_AGENT_KEY\)/);
    assert.match(listBody, /`\/api\/v1\/memory\?\$\{qs\}`/);

    const forgetStart = INDEX_SRC.indexOf("async function memoryForget(");
    const forgetBody = INDEX_SRC.slice(forgetStart, forgetStart + 500);
    assert.match(forgetBody, /apiCall\(\s*"DELETE",\s*`\/api\/v1\/memory\/\$\{id\}`,/);
  });

  test("every handler passes LOOPCTL_AGENT_KEY (agents are the intended caller)", () => {
    for (const fnName of ["memoryRemember", "memoryRecall", "memoryList", "memoryForget"]) {
      const start = INDEX_SRC.indexOf(`async function ${fnName}(`);
      const end = INDEX_SRC.indexOf("\n}\n", start);
      const body = INDEX_SRC.slice(start, end);
      assert.ok(
        /process\.env\.LOOPCTL_AGENT_KEY/.test(body),
        `${fnName} must route through LOOPCTL_AGENT_KEY`,
      );
    }
  });
});

describe("AC-28.4.2: descriptions disambiguate memory vs knowledge", () => {
  test("each of the four tool descriptions mentions both 'memory' and 'knowledge'", () => {
    for (const toolName of ["memory_remember", "memory_recall", "memory_list", "memory_forget"]) {
      const start = INDEX_SRC.indexOf(`name: "${toolName}",`);
      assert.ok(start !== -1, `${toolName} entry must exist`);
      const inputSchemaStart = INDEX_SRC.indexOf("inputSchema:", start);
      const descriptionBlock = INDEX_SRC.slice(start, inputSchemaStart);

      assert.match(
        descriptionBlock,
        /memory/i,
        `${toolName} description must mention "memory"`,
      );
      assert.match(
        descriptionBlock,
        /knowledge/i,
        `${toolName} description must mention "knowledge" to disambiguate from knowledge_*`,
      );
    }
  });
});

describe("AC-28.4.5: existing knowledge_*/story tools remain unchanged", () => {
  test("ListTools still exposes representative pre-existing tools alongside the new memory tools", () => {
    for (const toolName of [
      "knowledge_search",
      "knowledge_create",
      "knowledge_context",
      "knowledge_list",
      "knowledge_get",
      "list_projects",
      "get_progress",
    ]) {
      assert.ok(
        INDEX_SRC.includes(`name: "${toolName}",`),
        `pre-existing tool "${toolName}" must still be registered`,
      );
    }
  });

  test("ListToolsRequestSchema returns the TOOLS array as-is (append-only exposure)", () => {
    assert.match(INDEX_SRC, /server\.setRequestHandler\(ListToolsRequestSchema, async \(\) => \(\{\s*\n\s*tools: TOOLS,/);
  });
});
