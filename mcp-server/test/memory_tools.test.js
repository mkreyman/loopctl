/**
 * Tests for US-28.4: MCP memory_* tools (remember/recall/forget/list) with
 * memory-vs-knowledge docstrings, extended by US-29.4 for the fifth tool,
 * memory_promote (compiles a session's short-term memory into long-term
 * memory).
 *
 * Uses Node.js built-in test runner (node:test). Run: node --test test/
 *
 * Strategy (mirrors knowledge_tools.test.js / story_tools.test.js / mcp_arg_
 * forwarding.test.js): index.js is a stdio entry point with top-level await, so
 * its handlers cannot be imported directly. We combine:
 *
 *   - Source-assertion tests: read index.js as text and assert the TOOLS
 *     entries exist with disambiguating descriptions, a switch case each, and
 *     that the handlers route through apiCall (the shared witness-aware HTTP
 *     helper) to the correct /api/v1/memory* path + method (AC-28.4.1,
 *     AC-28.4.3, AC-28.4.5, AC-29.4.1, AC-29.4.3, AC-29.4.4).
 *   - Behavioral tests: a minimal reimplementation of the handler bodies
 *     (mirroring index.js exactly) exercised against a mocked fetch, covering
 *     the remember->recall happy path (TC-28.4.1), a non-self-healing
 *     auth/witness failure (TC-28.4.4), that recall/list meta
 *     (fallback/total_count) is surfaced (AC-28.4.4), and memory_promote's
 *     happy path / witness-412 self-heal / scope isolation (AC-29.4.5).
 *   - Scope isolation (TC-28.4.3 / AC-28.4.5 / AC-29.4.1 / AC-29.4.4): the
 *     memory tool inputSchemas must NOT accept tenant_id/subject_id/
 *     project_id, and handlers must never forward a body-supplied scope — the
 *     tool cannot even express a cross-scope read/write; scope is key-derived
 *     server-side (US-28.3/US-29.3's job to enforce there).
 *
 * TC-28.4.4 self-heal: the generic bootstrap-412 retry mechanics (single
 * retry, error.code anchoring, persistence, coalescing) are covered end-to-end
 * against createWitnessClient in witness_sth.test.js. That is NOT sufficient to
 * call TC-28.4.4 verified for memory tools, though — this file additionally
 * drives the shared witness client (imported directly from
 * ../lib/witness-sth.js, the same module index.js's apiCall delegates to via
 * witnessClientFor) through a `witness_bootstrap_already_consumed` 412 for a
 * memory_remember-shaped POST and asserts the write ultimately succeeds (see
 * "TC-28.4.4 self-heal" below). The one 412 test in the auth/witness-failure
 * block below uses `witness_header_malformed` instead — a 412 code that is
 * deliberately NOT self-healing (per witness-sth.js's error.code anchoring) —
 * so it documents the error-surfacing case without contradicting the
 * self-heal expectation for the bootstrap-grace code. AC-29.4.3's "self-heal"
 * requirement is verified separately for memory_promote below (mirrors the
 * same pattern for its POST /api/v1/memory/promote shape).
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { memoryPath } from "../lib/http-helpers.js";
import { createWitnessClient } from "../lib/witness-sth.js";

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
  // Routes through the REAL shared memoryPath helper (lib/http-helpers.js) —
  // not a hand-copied URLSearchParams mirror — so this behavioral test
  // exercises the same query-building code the server ships (finding: memory_list
  // hand-rolls query-string building instead of the shared buildQuery helper).
  const path = memoryPath({ limit, offset, include_superseded, all_subjects });
  const result = await apiCall("GET", path, null, process.env.LOOPCTL_AGENT_KEY);
  return toContent(result);
}

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

async function memoryForget({ id }) {
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

describe("memory_remember: metadata parity with the /api/v1/memory HTTP API", () => {
  test("forwards metadata to /api/v1/memory (the HTTP API accepts it; the MCP tool must not be narrower)", async () => {
    setupEnv();
    const memory = {
      id: "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0",
      tier: "long_term",
      text: "prefers Req over Tesla",
      metadata: { source: "code_review", pr: 320 },
    };
    const calls = mockFetch({ data: memory }, 201);

    const result = await memoryRemember({
      tier: "long_term",
      text: "prefers Req over Tesla",
      metadata: { source: "code_review", pr: 320 },
    });

    assert.equal(calls.length, 1);
    assert.deepEqual(JSON.parse(calls[0].options.body), {
      tier: "long_term",
      text: "prefers Req over Tesla",
      metadata: { source: "code_review", pr: 320 },
    });
    assert.equal(result.isError, undefined);
  });

  test("omits metadata entirely when not supplied (no `metadata: undefined` leaking into the payload)", async () => {
    setupEnv();
    const calls = mockFetch({ data: { id: "x", tier: "long_term", text: "y" } }, 201);

    await memoryRemember({ tier: "long_term", text: "y" });

    assert.equal("metadata" in JSON.parse(calls[0].options.body), false);
  });

  test("memory_remember inputSchema exposes a metadata property (index.js source)", () => {
    const start = INDEX_SRC.indexOf('name: "memory_remember",');
    assert.ok(start !== -1, "memory_remember TOOLS entry must exist");
    const nextEntry = INDEX_SRC.indexOf('\n    name: "', start + 20);
    const entryEnd = nextEntry === -1 ? start + 4000 : nextEntry;
    const schemaBlock = INDEX_SRC.slice(start, entryEnd);
    assert.match(
      schemaBlock,
      /metadata:\s*\{\s*\n\s*type:\s*"object",/,
      "memory_remember inputSchema must declare a metadata property (parity with the HTTP API's @memory_attr_keys)",
    );
  });

  test("index.js memoryRemember forwards metadata to the payload", () => {
    const start = INDEX_SRC.indexOf("async function memoryRemember(");
    const end = INDEX_SRC.indexOf("\n}\n", start);
    const body = INDEX_SRC.slice(start, end);
    assert.match(body, /if \(metadata != null\) payload\.metadata = metadata;/);
  });
});

// ---------------------------------------------------------------------------
// Review finding (US-28.4): the load-bearing forwarded fields (recall's payload
// build, remember's other nine forwards) had no source-assertion drift guard —
// only the hand-kept local mirror above. A regression dropping one of these
// forwards in the REAL index.js would keep this file's behavioral tests green
// (they exercise the local copy) and slip past the regexes that existed. These
// assertions read the real index.js source directly, closing that blind spot.
// ---------------------------------------------------------------------------

describe("source assertion: memoryRecall builds/forwards its full payload", () => {
  test("index.js memoryRecall builds {query} and conditionally forwards limit/include_superseded", () => {
    const start = INDEX_SRC.indexOf("async function memoryRecall(");
    assert.ok(start !== -1, "memoryRecall handler must exist");
    const end = INDEX_SRC.indexOf("\n}\n", start);
    const body = INDEX_SRC.slice(start, end);

    assert.match(
      body,
      /const payload = \{ query \};/,
      "memoryRecall must build the payload from `query`",
    );
    assert.match(
      body,
      /if \(limit != null\) payload\.limit = limit;/,
      "memoryRecall must forward `limit` when present",
    );
    assert.match(
      body,
      /if \(include_superseded != null\) payload\.include_superseded = include_superseded;/,
      "memoryRecall must forward `include_superseded` when present",
    );
  });
});

describe("source assertion: memoryRemember forwards every remaining field to the payload", () => {
  const FIELD_FORWARDS = {
    tier: /if \(tier\) payload\.tier = tier;/,
    text: /if \(text != null\) payload\.text = text;/,
    confidence: /if \(confidence != null\) payload\.confidence = confidence;/,
    tags: /if \(tags\) payload\.tags = tags;/,
    source_session_id: /if \(source_session_id\) payload\.source_session_id = source_session_id;/,
    session_id: /if \(session_id\) payload\.session_id = session_id;/,
    role: /if \(role\) payload\.role = role;/,
    content: /if \(content != null\) payload\.content = content;/,
    expires_at: /if \(expires_at\) payload\.expires_at = expires_at;/,
  };

  for (const [field, pattern] of Object.entries(FIELD_FORWARDS)) {
    test(`index.js memoryRemember forwards ${field} to the payload`, () => {
      const start = INDEX_SRC.indexOf("async function memoryRemember(");
      const end = INDEX_SRC.indexOf("\n}\n", start);
      const body = INDEX_SRC.slice(start, end);
      assert.match(body, pattern, `memoryRemember must forward \`${field}\` to the payload`);
    });
  }
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
// memory_list routes through the shared memoryPath helper (lib/http-helpers.js),
// not a hand-rolled URLSearchParams mirror — mirrors the projectsPath /
// ingestionJobsPath / llmUsagePath pattern in mcp_arg_forwarding.test.js, so a
// regression in this query-string logic fails CI instead of silently passing
// against a hand-copied mirror.
// ---------------------------------------------------------------------------

describe("memory_list pagination (real memoryPath)", () => {
  test("forwards limit/offset/include_superseded/all_subjects", () => {
    const url = new URL(
      `https://x${memoryPath({ limit: 10, offset: 5, include_superseded: true, all_subjects: true })}`,
    );
    assert.equal(url.pathname, "/api/v1/memory");
    assert.equal(url.searchParams.get("limit"), "10");
    assert.equal(url.searchParams.get("offset"), "5");
    assert.equal(url.searchParams.get("include_superseded"), "true");
    assert.equal(url.searchParams.get("all_subjects"), "true");
  });

  test("omits params when none are supplied", () => {
    assert.equal(memoryPath(), "/api/v1/memory");
    assert.equal(memoryPath({}), "/api/v1/memory");
  });

  test("index.js memoryList delegates to the shared memoryPath(...) (not a local URLSearchParams mirror)", () => {
    const start = INDEX_SRC.indexOf("async function memoryList(");
    assert.ok(start !== -1, "memoryList handler must exist");
    const end = INDEX_SRC.indexOf("\n}\n", start);
    const body = INDEX_SRC.slice(start, end);

    assert.match(
      body,
      /memoryPath\(\{ limit, offset, include_superseded, all_subjects \}\)/,
      "memoryList must delegate to the shared memoryPath helper",
    );
    assert.ok(
      !/new URLSearchParams\(\)/.test(body),
      "memoryList must not hand-roll its own URLSearchParams query building",
    );
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

  // NOTE: this uses `witness_header_malformed` — a 412 code witness-sth.js
  // deliberately does NOT self-heal (error.code anchoring, see
  // createWitnessClient's retrySthFor) — NOT `witness_bootstrap_already_consumed`.
  // The bootstrap-grace code IS self-healed transparently by the shared witness
  // client; asserting an error result for THAT code would contradict TC-28.4.4's
  // self-heal expectation. See the "TC-28.4.4 self-heal" describe block below for
  // the case that exercises the real bootstrap-412 retry end-to-end.
  test("a 412 witness_header_malformed (non-self-healing) from memory_recall returns {error:true, status:412}", async () => {
    setupEnv();
    mockFetch(
      { error: { status: 412, code: "witness_header_malformed" } },
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

// ---------------------------------------------------------------------------
// TC-28.4.4 self-heal: the bootstrap-grace 412 is retried ONCE, transparently,
// and the memory write ultimately succeeds — driven through the REAL shared
// witness client (../lib/witness-sth.js), the same module index.js's apiCall
// delegates to via witnessClientFor(key).send(...). This is what makes
// TC-28.4.4's named expected result ("the 412 retry succeeds (self-heal) and
// the memory is written") actually verified for a memory tool, rather than
// only for the generic mechanics in witness_sth.test.js.
// ---------------------------------------------------------------------------

describe("TC-28.4.4 self-heal: memory_remember survives a bootstrap-grace 412", () => {
  test("the SAME memory_remember-shaped POST is retried once by the shared witness client, and the write succeeds", async () => {
    const STH = "5:AAAAAAAAAAAAAAAAAAAAAA";
    const storedMemory = {
      id: "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0",
      tier: "long_term",
      text: "prefers Req over Tesla",
    };
    let callCount = 0;
    const calls = [];

    const fetchImpl = async (url, options) => {
      callCount += 1;
      calls.push({ url, options });

      if (callCount === 1) {
        // First attempt hits the bootstrap-grace 412 — the one code the shared
        // witness client transparently retries (error.code anchored).
        const body = { error: { status: 412, code: "witness_bootstrap_already_consumed" } };
        return {
          status: 412,
          headers: { get: (name) => (name.toLowerCase() === "x-loopctl-current-sth" ? STH : null) },
          clone() {
            return { async json() { return body; } };
          },
        };
      }

      // Retry succeeds — the memory is actually written.
      return {
        status: 201,
        headers: {
          get: (name) => {
            const lower = name.toLowerCase();
            if (lower === "x-loopctl-current-sth") return STH;
            if (lower === "content-type") return "application/json";
            return null;
          },
        },
        async json() { return { data: storedMemory }; },
        async text() { return JSON.stringify({ data: storedMemory }); },
      };
    };

    const client = createWitnessClient({ fetchImpl });
    const payload = { tier: "long_term", text: "prefers Req over Tesla" };

    const response = await client.send({
      url: `${BASE_URL}/api/v1/memory`,
      method: "POST",
      headers: {
        Authorization: `Bearer ${AGENT_KEY}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      serializedBody: JSON.stringify(payload),
    });

    // Exactly one transparent retry — the FIRST attempt bootstraps (no cached
    // STH yet), the SECOND carries the learned STH and succeeds.
    assert.equal(callCount, 2);
    assert.equal(calls[0].options.headers["X-Loopctl-STH-Bootstrap"], "true");
    assert.equal(calls[1].options.headers["X-Loopctl-Last-Known-STH"], STH);

    // The retry's response is the one apiCall/memoryRemember would surface to
    // the caller — the write succeeded, not an error.
    assert.equal(response.status, 201);
    const body = await response.json();
    assert.deepEqual(body, { data: storedMemory });
    assert.equal(client.getSTH(), STH);
  });
});

// ---------------------------------------------------------------------------
// US-29.4: memory_promote — compiles a session's short-term memory into
// durable long-term memory, once, at session end.
// ---------------------------------------------------------------------------

describe("TC-29.4.1: memory_promote happy path", () => {
  test("POSTs {session_id} to /api/v1/memory/promote with the agent key and returns the 202 result", async () => {
    setupEnv();
    const enqueued = {
      job_id: "9c1f2e10-6b3a-4e9d-9b5a-2f6a1c8d4e77",
      session_id: "sess-abc-123",
      status: "enqueued",
    };
    const calls = mockFetch({ data: enqueued }, 202);

    const result = await memoryPromote({ session_id: "sess-abc-123" });

    assert.equal(calls.length, 1);
    const { url, options } = calls[0];
    assert.equal(new URL(url).pathname, "/api/v1/memory/promote");
    assert.equal(options.method, "POST");
    assert.equal(options.headers.Authorization, `Bearer ${AGENT_KEY}`);
    assert.deepEqual(JSON.parse(options.body), { session_id: "sess-abc-123" });
    assert.equal(result.isError, undefined);
    assert.deepEqual(JSON.parse(result.content[0].text), { data: enqueued });
  });

  test("a 429 promotion_budget_exceeded from memory_promote returns a structured error, not a throw", async () => {
    setupEnv();
    mockFetch(
      { error: { status: 429, code: "promotion_budget_exceeded" } },
      429,
    );

    const result = await memoryPromote({ session_id: "sess-over-budget" });

    assert.equal(result.isError, true);
    const parsed = JSON.parse(result.content[0].text);
    assert.equal(parsed.status, 429);
    assert.equal(parsed.body.error.code, "promotion_budget_exceeded");
  });
});

// ---------------------------------------------------------------------------
// AC-29.4.3 / AC-29.4.5: memory_promote self-heals on the bootstrap-grace 412
// exactly like every other memory write tool — driven through the REAL shared
// witness client (mirrors the TC-28.4.4 self-heal block above).
// ---------------------------------------------------------------------------

describe("AC-29.4.3 self-heal: memory_promote survives a bootstrap-grace 412", () => {
  test("the SAME memory_promote-shaped POST is retried once by the shared witness client, and the promote succeeds", async () => {
    const STH = "5:AAAAAAAAAAAAAAAAAAAAAA";
    const enqueued = {
      job_id: "9c1f2e10-6b3a-4e9d-9b5a-2f6a1c8d4e77",
      session_id: "sess-abc-123",
      status: "enqueued",
    };
    let callCount = 0;
    const calls = [];

    const fetchImpl = async (url, options) => {
      callCount += 1;
      calls.push({ url, options });

      if (callCount === 1) {
        const body = { error: { status: 412, code: "witness_bootstrap_already_consumed" } };
        return {
          status: 412,
          headers: { get: (name) => (name.toLowerCase() === "x-loopctl-current-sth" ? STH : null) },
          clone() {
            return { async json() { return body; } };
          },
        };
      }

      return {
        status: 202,
        headers: {
          get: (name) => {
            const lower = name.toLowerCase();
            if (lower === "x-loopctl-current-sth") return STH;
            if (lower === "content-type") return "application/json";
            return null;
          },
        },
        async json() { return { data: enqueued }; },
        async text() { return JSON.stringify({ data: enqueued }); },
      };
    };

    const client = createWitnessClient({ fetchImpl });
    const payload = { session_id: "sess-abc-123" };

    const response = await client.send({
      url: `${BASE_URL}/api/v1/memory/promote`,
      method: "POST",
      headers: {
        Authorization: `Bearer ${AGENT_KEY}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      serializedBody: JSON.stringify(payload),
    });

    assert.equal(callCount, 2, "exactly one transparent retry");
    assert.equal(calls[0].options.headers["X-Loopctl-STH-Bootstrap"], "true");
    assert.equal(calls[1].options.headers["X-Loopctl-Last-Known-STH"], STH);

    assert.equal(response.status, 202);
    const body = await response.json();
    assert.deepEqual(body, { data: enqueued });
    assert.equal(client.getSTH(), STH);
  });
});

// ---------------------------------------------------------------------------
// AC-29.4.1 / AC-29.4.4: memory_promote scope isolation — input is session_id
// ONLY; the tool cannot express or smuggle tenant_id/subject_id/project_id.
// ---------------------------------------------------------------------------

describe("AC-29.4.1 / AC-29.4.4: memory_promote scope isolation", () => {
  test("memoryPromote destructures ONLY {session_id} — no tenant_id/subject_id/project_id param to bind", () => {
    const start = INDEX_SRC.indexOf("async function memoryPromote(");
    assert.ok(start !== -1, "memoryPromote handler must exist");

    const sigEnd = INDEX_SRC.indexOf(")", start);
    const signature = INDEX_SRC.slice(start, sigEnd);
    assert.match(
      signature,
      /\{\s*session_id\s*\}/,
      "memoryPromote must destructure exactly {session_id}",
    );
    assert.ok(!/tenant_id/.test(signature), "memoryPromote must not destructure tenant_id");
    assert.ok(!/subject_id/.test(signature), "memoryPromote must not destructure subject_id");
    assert.ok(!/project_id/.test(signature), "memoryPromote must not destructure project_id");
  });

  test("memory_promote inputSchema exposes only session_id — no tenant_id/subject_id/project_id property", () => {
    const toolStart = INDEX_SRC.indexOf('name: "memory_promote",');
    assert.ok(toolStart !== -1, "memory_promote TOOLS entry must exist");
    const nextEntry = INDEX_SRC.indexOf('\n    name: "', toolStart + 20);
    const entryEnd = nextEntry === -1 ? toolStart + 3000 : nextEntry;
    const inputSchemaStart = INDEX_SRC.indexOf("inputSchema:", toolStart);
    assert.ok(inputSchemaStart !== -1 && inputSchemaStart < entryEnd, "memory_promote must have an inputSchema");
    const schemaBlock = INDEX_SRC.slice(inputSchemaStart, entryEnd);

    assert.match(schemaBlock, /session_id:\s*\{/, "memory_promote inputSchema must declare session_id");
    assert.ok(!/\btenant_id\b/.test(schemaBlock), "memory_promote inputSchema must not expose tenant_id");
    assert.ok(!/\bsubject_id\b/.test(schemaBlock), "memory_promote inputSchema must not expose subject_id");
    assert.ok(!/\bproject_id\b/.test(schemaBlock), "memory_promote inputSchema must not expose project_id");
  });

  test("a forged tenant_id/subject_id/project_id passed to memoryPromote is not forwarded to the wire", async () => {
    setupEnv();
    const calls = mockFetch({ data: { job_id: "x", session_id: "s", status: "enqueued" } }, 202);

    await memoryPromote({
      session_id: "sess-abc-123",
      tenant_id: "victim-tenant",
      subject_id: "victim-subject",
      project_id: "victim-project",
    });

    assert.equal(calls.length, 1);
    assert.deepEqual(JSON.parse(calls[0].options.body), { session_id: "sess-abc-123" });
  });

  test("memoryPromote only ever calls apiCall (never a raw fetch)", () => {
    const start = INDEX_SRC.indexOf("async function memoryPromote(");
    const end = INDEX_SRC.indexOf("\n}\n", start);
    const body = INDEX_SRC.slice(start, end);

    assert.ok(/apiCall\(/.test(body), "memoryPromote must call apiCall(...) — inherits witness/STH");
    assert.ok(!/(?<!api)fetch\(/i.test(body), "memoryPromote must not call a raw fetch");
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
// Review finding (US-28.4): memory_forget interpolates the caller-supplied `id`
// into a destructive DELETE URL path with no UUID validation, unlike the file's
// own proven UUID_RE guard (knowledgeAgentUsage, index.js). Fixed by validating
// against UUID_RE before the network call — mirrored here in both the
// behavioral mock and a source assertion against the real index.js.
// ---------------------------------------------------------------------------

describe("memory_forget: rejects a non-UUID id before touching the network (path-injection guard)", () => {
  test("a path-traversal-shaped id is rejected with a structured error, no fetch call", async () => {
    setupEnv();
    const calls = mockFetch({ data: { id: "x", deleted: true } }, 200);

    const result = await memoryForget({ id: "../other-tenant/secret" });

    assert.equal(calls.length, 0, "must not touch the network with an invalid id");
    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /canonical UUID/);
  });

  test("a slash-shaped id is rejected with a structured error, no fetch call", async () => {
    setupEnv();
    const calls = mockFetch({ data: { id: "x", deleted: true } }, 200);

    const result = await memoryForget({ id: "abc/def" });

    assert.equal(calls.length, 0);
    assert.equal(result.isError, true);
  });

  test("a canonical UUID still passes through to apiCall", async () => {
    setupEnv();
    const id = "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0";
    const calls = mockFetch({ data: { id, deleted: true } }, 200);

    const result = await memoryForget({ id });

    assert.equal(calls.length, 1);
    assert.equal(result.isError, undefined);
  });

  test("index.js memoryForget validates id against UUID_RE before calling apiCall (source assertion)", () => {
    const start = INDEX_SRC.indexOf("async function memoryForget(");
    assert.ok(start !== -1, "memoryForget handler must exist");
    const end = INDEX_SRC.indexOf("\n}\n", start);
    const body = INDEX_SRC.slice(start, end);

    assert.match(
      body,
      /if \(typeof id !== "string" \|\| !UUID_RE\.test\(id\)\)/,
      "memoryForget must validate id against UUID_RE before the destructive DELETE (path-injection guard)",
    );

    const apiCallIndex = body.indexOf("apiCall(");
    const guardIndex = body.indexOf("UUID_RE.test(id)");
    assert.ok(
      guardIndex !== -1 && guardIndex < apiCallIndex,
      "the UUID_RE guard must run BEFORE the apiCall/network call, not after",
    );
  });
});

// ---------------------------------------------------------------------------
// TC-28.4.3 / AC-28.4.5: scope isolation — the tool cannot even express a
// cross-scope read/write. Scope is key-derived server-side (US-28.3's job);
// here we assert the MCP layer provides no bypass surface.
// ---------------------------------------------------------------------------

describe("TC-28.4.3: scope isolation — no tenant_id/subject_id bypass surface", () => {
  test("none of the five memory tool inputSchemas accept tenant_id or subject_id", () => {
    for (const toolName of [
      "memory_remember",
      "memory_recall",
      "memory_list",
      "memory_forget",
      "memory_promote",
    ]) {
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
    for (const fnName of [
      "memoryRemember",
      "memoryRecall",
      "memoryList",
      "memoryForget",
      "memoryPromote",
    ]) {
      const start = INDEX_SRC.indexOf(`async function ${fnName}(`);
      assert.ok(start !== -1, `${fnName} handler must exist`);
      const end = INDEX_SRC.indexOf("\n}\n", start);
      const body = INDEX_SRC.slice(start, end);

      assert.ok(!/tenant_id/.test(body), `${fnName} must not reference tenant_id`);
      assert.ok(!/subject_id/.test(body), `${fnName} must not reference subject_id`);
    }
  });

  test("memoryRemember/memoryRecall/memoryList/memoryForget/memoryPromote only ever call apiCall (never a raw fetch)", () => {
    for (const fnName of [
      "memoryRemember",
      "memoryRecall",
      "memoryList",
      "memoryForget",
      "memoryPromote",
    ]) {
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

describe("AC-28.4.1 / AC-29.4.1: five memory tools registered by the existing convention", () => {
  test("TOOLS array has an entry for each of the five tools", () => {
    for (const toolName of [
      "memory_remember",
      "memory_recall",
      "memory_list",
      "memory_forget",
      "memory_promote",
    ]) {
      assert.ok(
        INDEX_SRC.includes(`name: "${toolName}",`),
        `TOOLS array must have an entry named "${toolName}"`,
      );
    }
  });

  test("CallToolRequestSchema switch has a case for each of the five tools", () => {
    assert.match(INDEX_SRC, /case "memory_remember":\s*\n\s*return await memoryRemember\(args\);/);
    assert.match(INDEX_SRC, /case "memory_recall":\s*\n\s*return await memoryRecall\(args\);/);
    assert.match(INDEX_SRC, /case "memory_list":\s*\n\s*return await memoryList\(args\);/);
    assert.match(INDEX_SRC, /case "memory_forget":\s*\n\s*return await memoryForget\(args\);/);
    assert.match(INDEX_SRC, /case "memory_promote":\s*\n\s*return await memoryPromote\(args\);/);
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
    assert.match(listBody, /memoryPath\(\{ limit, offset, include_superseded, all_subjects \}\)/);

    const forgetStart = INDEX_SRC.indexOf("async function memoryForget(");
    const forgetBody = INDEX_SRC.slice(forgetStart, forgetStart + 500);
    assert.match(forgetBody, /apiCall\(\s*"DELETE",\s*`\/api\/v1\/memory\/\$\{id\}`,/);

    const promoteStart = INDEX_SRC.indexOf("async function memoryPromote(");
    const promoteBody = INDEX_SRC.slice(promoteStart, promoteStart + 500);
    assert.match(promoteBody, /apiCall\(\s*"POST",\s*"\/api\/v1\/memory\/promote",/);
  });

  test("every handler passes LOOPCTL_AGENT_KEY (agents are the intended caller)", () => {
    for (const fnName of [
      "memoryRemember",
      "memoryRecall",
      "memoryList",
      "memoryForget",
      "memoryPromote",
    ]) {
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

describe("AC-28.4.2 / AC-29.4.2: descriptions disambiguate memory vs knowledge", () => {
  test("each of the five tool descriptions mentions both 'memory' and 'knowledge'", () => {
    for (const toolName of [
      "memory_remember",
      "memory_recall",
      "memory_list",
      "memory_forget",
      "memory_promote",
    ]) {
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

  test("memory_promote's description literally states when to call it and disambiguates from memory_remember", () => {
    const start = INDEX_SRC.indexOf('name: "memory_promote",');
    assert.ok(start !== -1, "memory_promote entry must exist");
    const inputSchemaStart = INDEX_SRC.indexOf("inputSchema:", start);
    const descriptionBlock = INDEX_SRC.slice(start, inputSchemaStart);

    assert.match(
      descriptionBlock,
      /call at session end to compile this session's short-term memory into durable long-term memory/i,
      "memory_promote description must literally contain the AC-29.4.2 phrase",
    );
    assert.match(
      descriptionBlock,
      /once at session end/i,
      "memory_promote description must state it fires once at session end, not per turn",
    );
    assert.match(
      descriptionBlock,
      /memory_remember/,
      "memory_promote description must disambiguate itself from memory_remember",
    );
  });
});

// ---------------------------------------------------------------------------
// US-28.5 (AC-28.5.4): cross-surface isolation at the MCP layer. The context and
// API surfaces are proven in the Elixir suites
// (Loopctl.Memory.CrossSurfaceIsolationTest); here we prove the MCP surface
// offers NO bypass — a caller cannot express, nor smuggle, a cross-tenant /
// cross-subject scope. Scope is key-derived server-side; the tool is scope-blind.
// ---------------------------------------------------------------------------

describe("AC-28.5.4: MCP memory tools cannot express or smuggle a cross-scope read/write", () => {
  test("the REAL index.js memoryRecall destructures ONLY {query,limit,include_superseded} — a forged tenant_id/subject_id has no param to bind and never reaches the wire", () => {
    // A behavioral test that forged tenant_id/subject_id into the file-local
    // memoryRecall would be TAUTOLOGICAL: that local mirror drops the scope keys
    // in its OWN destructure, so the assertion is guaranteed by the test's own
    // function and cannot detect a regression in the shipped handler. index.js is
    // a stdio entry point (top-level await) and cannot be imported, so — following
    // this file's source-assertion convention — we prove the property against the
    // REAL handler's source: the destructured param list is the ONLY surface a
    // caller's args can bind to, and the body builds the wire payload only from it.
    const start = INDEX_SRC.indexOf("async function memoryRecall(");
    assert.ok(start !== -1, "memoryRecall handler must exist");

    const sigEnd = INDEX_SRC.indexOf(")", start);
    const signature = INDEX_SRC.slice(start, sigEnd);
    assert.match(
      signature,
      /\{\s*query,\s*limit,\s*include_superseded\s*\}/,
      "memoryRecall must destructure exactly {query, limit, include_superseded}",
    );
    assert.ok(
      !/tenant_id/.test(signature),
      "memoryRecall must not destructure a tenant_id param (no surface for a forged scope)",
    );
    assert.ok(
      !/subject_id/.test(signature),
      "memoryRecall must not destructure a subject_id param (no surface for a forged scope)",
    );

    const end = INDEX_SRC.indexOf("\n}\n", start);
    const body = INDEX_SRC.slice(start, end);
    assert.match(
      body,
      /const payload = \{ query \};/,
      "memoryRecall must build the wire payload from `query` alone (then conditionally limit/include_superseded)",
    );
    assert.ok(!/tenant_id/.test(body), "memoryRecall body must never reference tenant_id");
    assert.ok(!/subject_id/.test(body), "memoryRecall body must never reference subject_id");
  });

  test("a forged tenant_id/subject_id passed to memory_list is NOT forwarded to the query string", async () => {
    setupEnv();
    const calls = mockFetch({ data: [], meta: { total_count: 0, limit: 50, offset: 0 } }, 200);

    await memoryList({ limit: 5, tenant_id: "victim-tenant", subject_id: "victim-subject" });

    const parsedUrl = new URL(calls[0].url);
    assert.equal(parsedUrl.searchParams.has("tenant_id"), false);
    assert.equal(parsedUrl.searchParams.has("subject_id"), false);
  });

  test("memory_forget targets ONLY the :id path segment — no scope param can widen its blast radius", async () => {
    setupEnv();
    const id = "b50c9e38-aebe-4bbe-b8e6-bf2cb2b8afd0";
    const calls = mockFetch({ data: { id, deleted: true } }, 200);

    // Extra forged scope keys are ignored; the DELETE hits exactly /api/v1/memory/:id,
    // which the server confines to the key's own (tenant, subject) scope (404 otherwise).
    await memoryForget({ id, tenant_id: "victim-tenant", subject_id: "victim-subject" });

    assert.equal(calls.length, 1);
    assert.equal(new URL(calls[0].url).pathname, `/api/v1/memory/${id}`);
    assert.equal(calls[0].options.body, undefined);
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

// ---------------------------------------------------------------------------
// TC-29.4.2: ListTools includes memory_promote alongside the epic_28 memory_*
// tools; existing tools (memory_remember/recall/list/forget + representative
// knowledge_*/story tools) are unchanged (AC-29.4.4).
// ---------------------------------------------------------------------------

describe("TC-29.4.2: ListTools includes memory_promote alongside all pre-existing tools", () => {
  test("TOOLS array has an entry for memory_promote AND memory_remember/recall/list/forget remain", () => {
    for (const toolName of [
      "memory_promote",
      "memory_remember",
      "memory_recall",
      "memory_list",
      "memory_forget",
    ]) {
      assert.ok(
        INDEX_SRC.includes(`name: "${toolName}",`),
        `TOOLS array must have an entry named "${toolName}"`,
      );
    }
  });

  test("representative pre-existing knowledge_*/story tools are unaffected by the new tool", () => {
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
});
