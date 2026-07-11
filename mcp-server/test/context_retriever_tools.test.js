/**
 * Tests for US-30.5: Dynamic MCP tool listing — append per-tenant generated
 * Context Retriever tools, dispatch `cr_`-prefixed calls generically.
 *
 * Uses the Node.js built-in test runner (node:test). Run: node --test test/*.test.js
 *
 * Strategy (see test/knowledge_tools.test.js): the handler functions in index.js
 * are not exported (it's a server entry point with top-level await). We mirror the
 * minimal apiCall/toContent + the ListTools/CallTool generated-tool logic here and
 * stub `globalThis.fetch` to return canned /retrieve/tools and /retrieve/:entity
 * responses.
 *
 * SINGLE SOURCE OF TRUTH: the path builders + spec/body mappers that carry the
 * real wire contract (retrieveToolsPath, retrieveEntityPath, specToMcpTool,
 * buildRetrieveBody) live in ../lib/http-helpers.js and are imported by BOTH the
 * shipped server (index.js) and these tests — so a regression in that logic fails
 * CI. Additional assertions read index.js source to pin the WIRING (that the real
 * handlers call the shared helpers and route generated calls through the same
 * `apiCall`/witness path as static reads).
 */

import { test, describe, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  retrieveToolsPath,
  retrieveEntityPath,
  specToMcpTool,
  buildRetrieveBody,
} from "../lib/http-helpers.js";

const INDEX_SRC = readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "index.js"),
  "utf8",
);

// ---------------------------------------------------------------------------
// Minimal re-implementation of the helpers under test (mirrors index.js)
// ---------------------------------------------------------------------------

const GENERATED_TOOL_PREFIX = "cr_";

function getBaseUrl() {
  return (process.env.LOOPCTL_SERVER || "https://loopctl.com").replace(/\/$/, "");
}

function resolveKey(keyOverride) {
  return process.env.LOOPCTL_API_KEY || keyOverride || process.env.LOOPCTL_ORCH_KEY;
}

// Mirrors index.js apiCall, including the witness-client STH header the real path
// injects (via witnessClientFor) — we add it here identically for EVERY call so a
// test can assert a generated call carries the same auth + witness header as a
// static read (TC-30.5.5).
async function apiCall(method, path, body, keyOverride) {
  const url = `${getBaseUrl()}${path}`;
  const key = resolveKey(keyOverride);

  if (!key) {
    return { error: true, status: 0, body: "No API key configured." };
  }

  const headers = {
    Authorization: `Bearer ${key}`,
    "Content-Type": "application/json",
    Accept: "application/json",
    // Stand-in for the witness client's per-key STH header. The real apiCall
    // routes through witnessClientFor(key).send which adds this; both static and
    // generated calls take that same path, so both carry it identically.
    "X-Loopctl-Last-Known-STH": `sth-for:${key}`,
  };

  const options = { method, headers };
  if (body !== undefined && body !== null) options.body = JSON.stringify(body);

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

// A fresh generated-tools runtime per test (closes over its own cache/metadata),
// mirroring the module-level state + functions in index.js. Avoids cross-test
// pollution while faithfully modeling the fetch/degrade/dispatch behavior.
function makeRuntime(staticTools = []) {
  let cache = { tools: [], fetchedAt: 0 };
  let metadataByName = new Map();
  const TTL_MS = 30_000;

  async function fetchGeneratedTools() {
    const now = Date.now();
    if (cache.fetchedAt !== 0 && now - cache.fetchedAt < TTL_MS) return cache.tools;

    let result;
    try {
      result = await apiCall("GET", retrieveToolsPath(), null, process.env.LOOPCTL_AGENT_KEY);
    } catch (err) {
      console.error(`degrade: ${err.message}`);
      return cache.tools;
    }
    if (result && result.error === true) {
      console.error(`degrade: HTTP ${result.status}`);
      return cache.tools;
    }

    const specs = result && Array.isArray(result.data) ? result.data : [];
    const tools = [];
    const metadata = new Map();
    for (const spec of specs) {
      const tool = specToMcpTool(spec);
      if (!tool) continue;
      tools.push(tool);
      if (spec.metadata && typeof spec.metadata === "object") metadata.set(spec.name, spec.metadata);
    }
    metadataByName = metadata;
    cache = { tools, fetchedAt: now };
    return tools;
  }

  async function resolveMetadata(name) {
    if (metadataByName.has(name)) return metadataByName.get(name);
    await fetchGeneratedTools();
    return metadataByName.get(name) || null;
  }

  async function callGeneratedTool(name, args = {}) {
    const metadata = await resolveMetadata(name);
    if (!metadata || typeof metadata.entity !== "string" || typeof metadata.operation !== "string") {
      return toContent({ error: true, status: 404, body: `Unknown tool: ${name}.` });
    }
    const result = await apiCall(
      "POST",
      retrieveEntityPath(metadata.entity),
      buildRetrieveBody(metadata, args),
      process.env.LOOPCTL_AGENT_KEY,
    );
    return toContent(result);
  }

  async function listTools() {
    const generated = await fetchGeneratedTools();
    return { tools: [...staticTools, ...generated] };
  }

  // Mirrors the CallTool default branch: static tools dispatch above; unknown
  // `cr_`-prefixed names go to the generic handler; everything else throws.
  async function callTool(name, args, staticHandlers = {}) {
    if (Object.prototype.hasOwnProperty.call(staticHandlers, name)) {
      return await staticHandlers[name](args);
    }
    if (typeof name === "string" && name.startsWith(GENERATED_TOOL_PREFIX)) {
      return await callGeneratedTool(name, args);
    }
    throw new Error(`Unknown tool: ${name}`);
  }

  return { fetchGeneratedTools, callGeneratedTool, listTools, callTool };
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const AGENT_KEY = "lc_test_agent_key";
const ORCH_KEY = "lc_test_orch_key";
const BASE_URL = "https://loopctl.com";

// Static tools stand-in (a few real static names so we can assert non-regression).
const STATIC_TOOLS = [
  { name: "get_story", description: "Get a story.", inputSchema: { type: "object" } },
  { name: "knowledge_search", description: "Search the wiki.", inputSchema: { type: "object" } },
  { name: "memory_recall", description: "Recall memory.", inputSchema: { type: "object" } },
];

// A generated filter spec for `project.status`, as GET /retrieve/tools returns it
// (snake_case input_schema; metadata.operation is the JSON string "filter").
function filterProjectByStatusSpec() {
  return {
    name: "cr_filter_project_by_status",
    description: "Filter project records where status matches the given value.",
    input_schema: {
      type: "object",
      properties: {
        status: { type: "string" },
        limit: { type: "integer" },
        offset: { type: "integer" },
      },
      required: ["status"],
    },
    metadata: {
      entity: "project",
      backing_source: "projects",
      field: "status",
      operation: "filter",
      field_type: "string",
    },
  };
}

function searchStorySpec() {
  return {
    name: "cr_search_story",
    description: "Full-text search across story's searchable fields.",
    input_schema: {
      type: "object",
      properties: { query: { type: "string" }, limit: { type: "integer" }, offset: { type: "integer" } },
      required: ["query"],
    },
    metadata: {
      entity: "story",
      backing_source: "stories",
      field: null,
      operation: "search",
      searchable_fields: ["title"],
    },
  };
}

/**
 * Install a fetch stub that routes by URL path to a canned response, capturing
 * every call (url/options). `routes` maps a path suffix to `{ body, status }`.
 */
function mockFetchByPath(routes) {
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    const u = new URL(url);
    const match = Object.keys(routes).find((p) => u.pathname === p);
    const route = match ? routes[match] : { body: { error: "no route" }, status: 404 };
    const status = route.status ?? 200;
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: () => "application/json" },
      json: async () => route.body,
      text: async () => JSON.stringify(route.body),
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

beforeEach(() => setupEnv());

// ---------------------------------------------------------------------------
// Shared helper unit coverage (the real wire contract)
// ---------------------------------------------------------------------------

describe("http-helpers: retrieve path + spec/body mappers (single source of truth)", () => {
  test("retrieveToolsPath is the fixed literal route (no client tenant param)", () => {
    assert.equal(retrieveToolsPath(), "/api/v1/retrieve/tools");
  });

  test("retrieveEntityPath encodes the entity name", () => {
    assert.equal(retrieveEntityPath("project"), "/api/v1/retrieve/project");
    assert.equal(retrieveEntityPath("a/b"), "/api/v1/retrieve/a%2Fb");
  });

  test("specToMcpTool maps input_schema -> inputSchema and keeps name/description", () => {
    const tool = specToMcpTool(filterProjectByStatusSpec());
    assert.equal(tool.name, "cr_filter_project_by_status");
    assert.equal(tool.description.startsWith("Filter project"), true);
    assert.deepEqual(tool.inputSchema.required, ["status"]);
    assert.equal("input_schema" in tool, false, "no snake_case key leaks into the MCP tool");
  });

  test("specToMcpTool returns null for a malformed spec (no string name)", () => {
    assert.equal(specToMcpTool({ description: "x" }), null);
    assert.equal(specToMcpTool(null), null);
  });

  test("buildRetrieveBody (filter) uses metadata field + args.value, omits nullish", () => {
    const body = buildRetrieveBody(filterProjectByStatusSpec().metadata, { value: "active" });
    assert.deepEqual(body, { op: "filter", field: "status", value: "active" });
  });

  test("buildRetrieveBody (filter) passes limit/offset when present", () => {
    const body = buildRetrieveBody(filterProjectByStatusSpec().metadata, {
      value: "active",
      limit: 10,
      offset: 20,
    });
    assert.deepEqual(body, { op: "filter", field: "status", value: "active", limit: 10, offset: 20 });
  });

  test("buildRetrieveBody (search) uses args.query, no field", () => {
    const body = buildRetrieveBody(searchStorySpec().metadata, { query: "invoice" });
    assert.deepEqual(body, { op: "search", query: "invoice" });
  });

  test("buildRetrieveBody dispatches by metadata.operation, NOT by splitting the name", () => {
    // entity + field both contain underscores — name-splitting would be ambiguous.
    const metadata = { entity: "work_order", field: "customer_name", operation: "filter" };
    const body = buildRetrieveBody(metadata, { value: "acme" });
    assert.deepEqual(body, { op: "filter", field: "customer_name", value: "acme" });
  });
});

// ---------------------------------------------------------------------------
// TC-30.5.1: ListTools includes generated + static
// ---------------------------------------------------------------------------

describe("TC-30.5.1: ListTools merges generated + static", () => {
  test("cr_filter_project_by_status appears alongside static tools; static unchanged", async () => {
    mockFetchByPath({
      "/api/v1/retrieve/tools": { body: { data: [filterProjectByStatusSpec()] } },
    });
    const rt = makeRuntime(STATIC_TOOLS);

    const { tools } = await rt.listTools();
    const names = tools.map((t) => t.name);

    assert.ok(names.includes("cr_filter_project_by_status"), "generated tool present");
    assert.ok(names.includes("get_story"), "static story tool present");
    assert.ok(names.includes("knowledge_search"), "static knowledge tool present");
    assert.ok(names.includes("memory_recall"), "static memory tool present");

    // Static tools are unchanged and come first (no regression to their shape).
    assert.deepEqual(tools.slice(0, STATIC_TOOLS.length), STATIC_TOOLS);

    // The generated tool carries the camelCase inputSchema MCP expects.
    const gen = tools.find((t) => t.name === "cr_filter_project_by_status");
    assert.deepEqual(gen.inputSchema.required, ["status"]);
  });
});

// ---------------------------------------------------------------------------
// TC-30.5.2: dispatch generated call + static tool still works
// ---------------------------------------------------------------------------

describe("TC-30.5.2: generic dispatch of a cr_ call; static tool still works", () => {
  test("cr_filter_project_by_status {value:'active'} POSTs to /retrieve/project", async () => {
    const calls = mockFetchByPath({
      "/api/v1/retrieve/tools": { body: { data: [filterProjectByStatusSpec()] } },
      "/api/v1/retrieve/project": {
        body: { results: [{ id: "p1", status: "active" }], meta: { total_count: 1, limit: 50, offset: 0 } },
      },
    });
    const rt = makeRuntime(STATIC_TOOLS);
    await rt.listTools(); // populate metadata

    const result = await rt.callGeneratedTool("cr_filter_project_by_status", { value: "active" });
    assert.equal(result.isError, undefined);

    const post = calls.find((c) => new URL(c.url).pathname === "/api/v1/retrieve/project");
    assert.ok(post, "POST to /retrieve/project made");
    assert.equal(post.options.method, "POST");
    assert.deepEqual(JSON.parse(post.options.body), { op: "filter", field: "status", value: "active" });

    // The returned content includes the tenant projects from /retrieve.
    const payload = JSON.parse(result.content[0].text);
    assert.equal(payload.results[0].id, "p1");
  });

  test("a static tool (get_story) still dispatches via the static path", async () => {
    mockFetchByPath({
      "/api/v1/retrieve/tools": { body: { data: [filterProjectByStatusSpec()] } },
    });
    const rt = makeRuntime(STATIC_TOOLS);

    let staticCalled = false;
    const staticHandlers = {
      get_story: async () => {
        staticCalled = true;
        return toContent({ id: "s1" });
      },
    };

    const result = await rt.callTool("get_story", { story_id: "s1" }, staticHandlers);
    assert.equal(staticCalled, true, "static handler invoked, not the generic dispatcher");
    assert.equal(JSON.parse(result.content[0].text).id, "s1");
  });
});

// ---------------------------------------------------------------------------
// TC-30.5.3: cross-tenant omission / rejection
// ---------------------------------------------------------------------------

describe("TC-30.5.3: tenant scoping — only the process key's tenant's tools", () => {
  test("tenant_u's listing omits tenant_t's tools (server returns only caller's specs)", async () => {
    // The stdio process is one-tenant-per-process: /retrieve/tools returns ONLY
    // the calling key's tenant, so tenant_t's cr_ tool never appears for tenant_u.
    mockFetchByPath({
      "/api/v1/retrieve/tools": { body: { data: [filterProjectByStatusSpec()] } },
    });
    const rt = makeRuntime(STATIC_TOOLS);

    const { tools } = await rt.listTools();
    const names = tools.map((t) => t.name);
    assert.ok(names.includes("cr_filter_project_by_status"), "tenant_u's own tool present");
    assert.ok(!names.includes("cr_filter_secret_by_field"), "tenant_t's tool absent");
  });

  test("calling tenant_t's cr_ tool as tenant_u is rejected as unknown (no rows)", async () => {
    // tenant_u's /retrieve/tools does NOT include tenant_t's tool, so resolving its
    // metadata fails -> unknown-tool error, and NO /retrieve/:entity call is made.
    const calls = mockFetchByPath({
      "/api/v1/retrieve/tools": { body: { data: [filterProjectByStatusSpec()] } },
    });
    const rt = makeRuntime(STATIC_TOOLS);
    await rt.listTools();

    const result = await rt.callGeneratedTool("cr_filter_secret_by_field", { value: "x" });
    assert.equal(result.isError, true, "unknown cross-tenant tool rejected");
    assert.ok(JSON.parse(result.content[0].text).body.startsWith("Unknown tool:"));

    const retrieveCalls = calls.filter((c) => new URL(c.url).pathname.startsWith("/api/v1/retrieve/") &&
      new URL(c.url).pathname !== "/api/v1/retrieve/tools");
    assert.equal(retrieveCalls.length, 0, "no executor call made for a cross-tenant name");
  });
});

// ---------------------------------------------------------------------------
// TC-30.5.4: degrade to static tools when /retrieve/tools errors
// ---------------------------------------------------------------------------

describe("TC-30.5.4: /retrieve/tools error degrades to static tools", () => {
  test("fetch error -> static tools still returned, no throw, generated list empty", async () => {
    mockFetchByPath({
      "/api/v1/retrieve/tools": { body: { error: "boom" }, status: 500 },
    });
    const rt = makeRuntime(STATIC_TOOLS);

    const { tools } = await rt.listTools();
    // Exactly the static tools — no crash, no generated tools appended.
    assert.deepEqual(tools, STATIC_TOOLS);
  });

  test("network throw from fetch also degrades to static tools", async () => {
    globalThis.fetch = async () => {
      throw new Error("ECONNRESET");
    };
    const rt = makeRuntime(STATIC_TOOLS);

    const { tools } = await rt.listTools();
    assert.deepEqual(tools, STATIC_TOOLS);
  });
});

// ---------------------------------------------------------------------------
// TC-30.5.5: generated call rides the SAME auth + witness/STH path as a static read
// ---------------------------------------------------------------------------

describe("TC-30.5.5: witness/STH + auth parity with static reads", () => {
  test("a generated cr_ call carries the SAME auth + witness headers as a static read", async () => {
    const calls = mockFetchByPath({
      "/api/v1/retrieve/tools": { body: { data: [filterProjectByStatusSpec()] } },
      "/api/v1/retrieve/project": { body: { results: [], meta: { total_count: 0, limit: 50, offset: 0 } } },
      // A representative static read endpoint.
      "/api/v1/knowledge/search": { body: { articles: [] } },
    });
    const rt = makeRuntime(STATIC_TOOLS);
    await rt.listTools();

    // Static read (as knowledge_search does) — same shared apiCall + agent key.
    await apiCall("GET", "/api/v1/knowledge/search?q=x", null, process.env.LOOPCTL_AGENT_KEY);
    // Generated call.
    await rt.callGeneratedTool("cr_filter_project_by_status", { value: "active" });

    const staticCall = calls.find((c) => new URL(c.url).pathname === "/api/v1/knowledge/search");
    const genCall = calls.find((c) => new URL(c.url).pathname === "/api/v1/retrieve/project");

    assert.equal(
      genCall.options.headers.Authorization,
      staticCall.options.headers.Authorization,
      "same Authorization bearer as a static read",
    );
    assert.equal(
      genCall.options.headers.Authorization,
      `Bearer ${AGENT_KEY}`,
      "uses the agent key (query-capable), not a weaker/other key",
    );
    assert.equal(
      genCall.options.headers["X-Loopctl-Last-Known-STH"],
      staticCall.options.headers["X-Loopctl-Last-Known-STH"],
      "same witness/STH header as a static read (same witness client path)",
    );
  });
});

// ---------------------------------------------------------------------------
// Wiring assertions: pin that index.js actually uses the shared path (not a
// bespoke second HTTP path) and degrades to static.
// ---------------------------------------------------------------------------

describe("index.js wiring (source-level pins)", () => {
  test("imports the shared retrieve helpers from lib/http-helpers.js", () => {
    assert.ok(/retrieveToolsPath/.test(INDEX_SRC));
    assert.ok(/retrieveEntityPath/.test(INDEX_SRC));
    assert.ok(/specToMcpTool/.test(INDEX_SRC));
    assert.ok(/buildRetrieveBody/.test(INDEX_SRC));
  });

  test("ListTools handler appends generated tools to the static TOOLS array", () => {
    assert.ok(
      /tools:\s*\[\.\.\.TOOLS,\s*\.\.\.generated\]/.test(INDEX_SRC),
      "ListTools returns [...TOOLS, ...generated]",
    );
  });

  test("fetchGeneratedTools uses the shared apiCall + agent key (same witness path)", () => {
    assert.ok(
      /apiCall\("GET",\s*retrieveToolsPath\(\),\s*null,\s*process\.env\.LOOPCTL_AGENT_KEY\)/.test(INDEX_SRC),
      "generated-tool listing goes through apiCall with the agent key",
    );
  });

  test("generic dispatch POSTs through the shared apiCall + agent key", () => {
    assert.ok(
      /apiCall\(\s*"POST",\s*retrieveEntityPath\(metadata\.entity\)/.test(INDEX_SRC),
      "generated calls POST /retrieve/:entity via apiCall (same auth+witness as static reads)",
    );
    assert.ok(/process\.env\.LOOPCTL_AGENT_KEY/.test(INDEX_SRC));
  });

  test("CallTool default routes unknown cr_-prefixed names to the generic handler", () => {
    assert.ok(
      /name\.startsWith\(GENERATED_TOOL_PREFIX\)/.test(INDEX_SRC),
      "cr_-prefixed unknown names go to callGeneratedTool before throwing Unknown tool",
    );
  });
});
