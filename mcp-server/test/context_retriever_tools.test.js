/**
 * Tests for US-30.5: Dynamic MCP tool listing — append per-tenant generated
 * Context Retriever tools, dispatch `cr_`-prefixed calls generically.
 *
 * Uses the Node.js built-in test runner (node:test). Run: node --test test/*.test.js
 *
 * SINGLE SOURCE OF TRUTH: the generated-tools RUNTIME (fetch + short-timeout /
 * positive+negative TTL cache + generic dispatch + `cr_`-prefix/static-collision
 * hardening) lives in ../lib/generated-tools.js and is imported and exercised
 * DIRECTLY here — NOT via a hand-copied mirror. index.js wires the SHIPPED apiCall,
 * static tool names, and toContent into the SAME factory, so a regression in the
 * caching/TTL/negative-cache/error-classification edge cases fails CI. The path
 * builders + spec/body mappers (retrieveToolsPath/retrieveEntityPath/specToMcpTool/
 * buildRetrieveBody) live in ../lib/http-helpers.js, also imported by both. Source
 * pins (INDEX_SRC/GEN_SRC) additionally assert the wiring holds.
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
import {
  createGeneratedToolsRuntime,
  GENERATED_TOOL_PREFIX,
  GENERATED_TOOLS_FETCH_TIMEOUT_MS,
  GENERATED_TOOLS_NEGATIVE_TTL_MS,
  GENERATED_TOOLS_CACHE_TTL_MS,
} from "../lib/generated-tools.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const GEN_SRC = readFileSync(path.join(DIR, "..", "lib", "generated-tools.js"), "utf8");

// ---------------------------------------------------------------------------
// toContent stand-in (index.js does not export it; the runtime receives it as a
// dependency, so the test controls it — its exact shape is not under test here).
// ---------------------------------------------------------------------------

function toContent(result) {
  const isErr = result && result.error === true;
  return {
    content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    ...(isErr && { isError: true }),
  };
}

// ---------------------------------------------------------------------------
// Test doubles for the injected `apiCall` + a controllable clock.
// ---------------------------------------------------------------------------

const AGENT_KEY = "lc_test_agent_key";
const ORCH_KEY = "lc_test_orch_key";
const BASE_URL = "https://loopctl.com";

/**
 * A fake `apiCall` matching index.js's signature
 * `(method, path, body, key, opts) => Promise<result>`. Routes GET /retrieve/tools
 * to `tools()` and POST /retrieve/:entity to `entity(path, body)`. Records every
 * call (method/path/body/key/opts) so tests can assert the short timeout, the agent
 * key, and the request body. `tools`/`entity` may return a value, an
 * `{ error: true, status, body }` object, or throw (network failure).
 */
function makeApiCall({ tools, entity } = {}) {
  const calls = [];
  const apiCall = async (method, p, body, key, opts) => {
    calls.push({ method, path: p, body, key, opts });
    if (method === "GET" && p === retrieveToolsPath()) {
      return tools ? await tools() : { data: [] };
    }
    if (method === "POST") {
      return entity ? await entity(p, body) : { results: [], meta: {} };
    }
    return { error: true, status: 404, body: "no route" };
  };
  return { apiCall, calls };
}

function toolCalls(calls) {
  return calls.filter((c) => c.method === "GET" && c.path === retrieveToolsPath());
}

function clock(start = 1_000) {
  let t = start;
  return { now: () => t, advance: (ms) => (t += ms) };
}

/**
 * Build the runtime under test with the real factory, injecting the fake apiCall,
 * the agent-key getter (so calls carry the agent key like every static read), a
 * controllable clock, and a log spy.
 */
function makeRuntime({ apiCall, staticTools = [], now, logs } = {}) {
  return createGeneratedToolsRuntime({
    apiCall,
    agentKey: () => process.env.LOOPCTL_AGENT_KEY,
    staticToolNames: new Set(staticTools.map((t) => t.name)),
    toContent,
    now,
    log: (msg) => logs && logs.push(msg),
  });
}

// Static tools stand-in (a few real static names for non-regression + collision).
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

  // The REAL agent contract: the US-30.2 schema puts the value under the
  // field-named key (`required: ["status"]`, no `value` property), so a
  // schema-compliant agent calls the tool with `{ status: "active" }`.
  test("buildRetrieveBody (filter) sources the value from the schema field-named arg", () => {
    const spec = filterProjectByStatusSpec();
    const [requiredKey] = spec.input_schema.required;
    const body = buildRetrieveBody(spec.metadata, { [requiredKey]: "active" });
    assert.deepEqual(body, { op: "filter", field: "status", value: "active" });
  });

  test("buildRetrieveBody (filter) still tolerates a literal {value:...} arg", () => {
    const body = buildRetrieveBody(filterProjectByStatusSpec().metadata, { value: "active" });
    assert.deepEqual(body, { op: "filter", field: "status", value: "active" });
  });

  test("buildRetrieveBody (filter) prefers the field-named arg over a stray value arg", () => {
    const body = buildRetrieveBody(filterProjectByStatusSpec().metadata, {
      status: "active",
      value: "ignored",
    });
    assert.deepEqual(body, { op: "filter", field: "status", value: "active" });
  });

  test("buildRetrieveBody (filter) passes limit/offset when present", () => {
    const body = buildRetrieveBody(filterProjectByStatusSpec().metadata, {
      status: "active",
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
    const metadata = { entity: "work_order", field: "customer_name", operation: "filter" };
    const body = buildRetrieveBody(metadata, { customer_name: "acme" });
    assert.deepEqual(body, { op: "filter", field: "customer_name", value: "acme" });
  });
});

// ---------------------------------------------------------------------------
// TC-30.5.1: fetchGeneratedTools yields the generated specs (ListTools appends them)
// ---------------------------------------------------------------------------

describe("TC-30.5.1: fetchGeneratedTools returns the tenant's generated tools", () => {
  test("maps the /retrieve/tools specs into MCP tools with camelCase inputSchema", async () => {
    const { apiCall } = makeApiCall({ tools: () => ({ data: [filterProjectByStatusSpec()] }) });
    const rt = makeRuntime({ apiCall, staticTools: STATIC_TOOLS });

    const generated = await rt.fetchGeneratedTools();
    assert.deepEqual(
      generated.map((t) => t.name),
      ["cr_filter_project_by_status"],
    );
    assert.deepEqual(generated[0].inputSchema.required, ["status"]);
    // The ListTools handler merges [...TOOLS, ...generated]; simulate that merge.
    const listed = [...STATIC_TOOLS, ...generated].map((t) => t.name);
    assert.ok(listed.includes("get_story") && listed.includes("cr_filter_project_by_status"));
    assert.deepEqual(listed.slice(0, STATIC_TOOLS.length), STATIC_TOOLS.map((t) => t.name));
  });

  test("uses the SHORT fetch timeout (not the full 30s) for the init-time blocking fetch", async () => {
    const { apiCall, calls } = makeApiCall({ tools: () => ({ data: [] }) });
    const rt = makeRuntime({ apiCall });
    await rt.fetchGeneratedTools();
    const [get] = toolCalls(calls);
    assert.equal(get.opts.timeoutMs, GENERATED_TOOLS_FETCH_TIMEOUT_MS);
    assert.ok(GENERATED_TOOLS_FETCH_TIMEOUT_MS < 30_000, "short timeout is well under the 30s default");
  });
});

// ---------------------------------------------------------------------------
// TC-30.5.2: dispatch a generated call through the generic executor
// ---------------------------------------------------------------------------

describe("TC-30.5.2: generic dispatch of a cr_ call", () => {
  test("cr_filter_project_by_status {status:'active'} POSTs the value to /retrieve/project", async () => {
    const spec = filterProjectByStatusSpec();
    const { apiCall, calls } = makeApiCall({
      tools: () => ({ data: [spec] }),
      entity: () => ({ results: [{ id: "p1", status: "active" }], meta: { total_count: 1 } }),
    });
    const rt = makeRuntime({ apiCall, staticTools: STATIC_TOOLS });
    await rt.fetchGeneratedTools(); // populate metadata

    const [requiredKey] = spec.input_schema.required;
    const result = await rt.callGeneratedTool("cr_filter_project_by_status", { [requiredKey]: "active" });
    assert.equal(result.isError, undefined);

    const post = calls.find((c) => c.method === "POST");
    assert.equal(post.path, "/api/v1/retrieve/project");
    assert.deepEqual(post.body, { op: "filter", field: "status", value: "active" });

    const payload = JSON.parse(result.content[0].text);
    assert.equal(payload.results[0].id, "p1");
  });
});

// ---------------------------------------------------------------------------
// TC-30.5.3: tenant scoping — only the process key's tenant's tools
// ---------------------------------------------------------------------------

describe("TC-30.5.3: tenant scoping — only the process key's tenant's tools", () => {
  test("calling a name absent from this tenant's listing is rejected, no executor call", async () => {
    const { apiCall, calls } = makeApiCall({ tools: () => ({ data: [filterProjectByStatusSpec()] }) });
    const rt = makeRuntime({ apiCall, staticTools: STATIC_TOOLS });
    await rt.fetchGeneratedTools();

    const result = await rt.callGeneratedTool("cr_filter_secret_by_field", { value: "x" });
    assert.equal(result.isError, true);
    assert.ok(JSON.parse(result.content[0].text).body.startsWith("Unknown tool:"));

    const post = calls.find((c) => c.method === "POST");
    assert.equal(post, undefined, "no executor call made for a cross-tenant name");
  });
});

// ---------------------------------------------------------------------------
// TC-30.5.4 + short-timeout/negative-cache: degrade to static, don't hammer
// ---------------------------------------------------------------------------

describe("TC-30.5.4: /retrieve/tools failure degrades to static + negative-caches", () => {
  test("HTTP-error result -> empty generated list, logged, no throw", async () => {
    const logs = [];
    const { apiCall } = makeApiCall({ tools: () => ({ error: true, status: 500, body: "boom" }) });
    const rt = makeRuntime({ apiCall, staticTools: STATIC_TOOLS, logs });

    const generated = await rt.fetchGeneratedTools();
    assert.deepEqual(generated, [], "no generated tools appended on failure");
    assert.equal(rt.cacheState().ok, false, "failure is recorded as a negative cache entry");
    assert.ok(logs.some((m) => m.includes("degrading to static tools")), "failure logged");
  });

  test("network throw also degrades to static tools", async () => {
    const { apiCall } = makeApiCall({
      tools: () => {
        throw new Error("ECONNRESET");
      },
    });
    const rt = makeRuntime({ apiCall, staticTools: STATIC_TOOLS });
    assert.deepEqual(await rt.fetchGeneratedTools(), []);
    assert.equal(rt.cacheState().ok, false);
  });

  test("negative caching: repeated ListTools during an outage do NOT re-issue the fetch", async () => {
    const clk = clock();
    let attempts = 0;
    const { apiCall, calls } = makeApiCall({
      tools: () => {
        attempts += 1;
        return { error: true, status: 503, body: "down" };
      },
    });
    const rt = makeRuntime({ apiCall, staticTools: STATIC_TOOLS, now: clk.now });

    // Cold cache (fetchedAt=0): first fetch attempts once and negative-caches.
    await rt.fetchGeneratedTools();
    assert.equal(toolCalls(calls).length, 1);

    // Within the negative TTL: subsequent fetches serve the degraded list WITHOUT
    // re-issuing the (up-to-timeout) blocking fetch — the bug this closes.
    clk.advance(GENERATED_TOOLS_NEGATIVE_TTL_MS - 1);
    await rt.fetchGeneratedTools();
    await rt.fetchGeneratedTools();
    assert.equal(toolCalls(calls).length, 1, "no re-fetch inside the negative TTL");
    assert.equal(attempts, 1);

    // Once the short negative TTL lapses, it retries (self-heals).
    clk.advance(2);
    await rt.fetchGeneratedTools();
    assert.equal(toolCalls(calls).length, 2, "retries after the negative TTL lapses");
  });

  test("a successful fetch is cached for the positive TTL (no re-fetch within it)", async () => {
    const clk = clock();
    const { apiCall, calls } = makeApiCall({ tools: () => ({ data: [filterProjectByStatusSpec()] }) });
    const rt = makeRuntime({ apiCall, now: clk.now });

    await rt.fetchGeneratedTools();
    clk.advance(GENERATED_TOOLS_CACHE_TTL_MS - 1);
    await rt.fetchGeneratedTools();
    assert.equal(toolCalls(calls).length, 1, "warm positive cache serves without re-fetch");

    clk.advance(2);
    await rt.fetchGeneratedTools();
    assert.equal(toolCalls(calls).length, 2, "re-fetches after the positive TTL lapses");
  });
});

// ---------------------------------------------------------------------------
// Resolve-miss force refetch + 503-vs-404 error classification (findings 1 & 2)
// ---------------------------------------------------------------------------

describe("resolveGeneratedToolMetadata forces a refetch on a miss; errors are classified", () => {
  test("a tool created within the warm-TTL window resolves (forced refetch bypasses TTL)", async () => {
    const clk = clock();
    let specs = [filterProjectByStatusSpec()];
    const { apiCall, calls } = makeApiCall({
      tools: () => ({ data: specs }),
      entity: () => ({ results: [], meta: {} }),
    });
    const rt = makeRuntime({ apiCall, now: clk.now });

    await rt.fetchGeneratedTools(); // listing #1: only the filter tool
    assert.equal(toolCalls(calls).length, 1);

    // A search tool is created server-side; still inside the warm positive TTL.
    specs = [filterProjectByStatusSpec(), searchStorySpec()];
    clk.advance(GENERATED_TOOLS_CACHE_TTL_MS - 5);

    // Calling the newly-created name forces ONE refetch instead of a stale 404.
    const result = await rt.callGeneratedTool("cr_search_story", { query: "invoice" });
    assert.equal(result.isError, undefined, "resolved via forced refetch, not reported unknown");
    assert.equal(toolCalls(calls).length, 2, "forced refetch happened despite the warm TTL");

    const post = calls.find((c) => c.method === "POST");
    assert.deepEqual(post.body, { op: "search", query: "invoice" });
  });

  test("an already-known name does NOT force a refetch (metadata hit short-circuits)", async () => {
    const { apiCall, calls } = makeApiCall({
      tools: () => ({ data: [filterProjectByStatusSpec()] }),
      entity: () => ({ results: [], meta: {} }),
    });
    const rt = makeRuntime({ apiCall });
    await rt.fetchGeneratedTools();
    await rt.callGeneratedTool("cr_filter_project_by_status", { status: "active" });
    assert.equal(toolCalls(calls).length, 1, "no extra fetch for an already-known tool");
  });

  test("unknown name with a HEALTHY listing -> definitive 404 unknown-to-tenant", async () => {
    const { apiCall } = makeApiCall({ tools: () => ({ data: [filterProjectByStatusSpec()] }) });
    const rt = makeRuntime({ apiCall });
    const result = await rt.callGeneratedTool("cr_nope", {});
    const body = JSON.parse(result.content[0].text);
    assert.equal(result.isError, true);
    assert.equal(body.status, 404);
    assert.ok(body.body.startsWith("Unknown tool:"));
  });

  test("unknown name while the tools fetch is FAILING -> 503 temporarily-unavailable (not a false 404)", async () => {
    const { apiCall } = makeApiCall({ tools: () => ({ error: true, status: 502, body: "gateway" }) });
    const rt = makeRuntime({ apiCall });
    const result = await rt.callGeneratedTool("cr_filter_project_by_status", { status: "active" });
    const body = JSON.parse(result.content[0].text);
    assert.equal(result.isError, true);
    assert.equal(body.status, 503, "transient fetch failure is not conflated with an unknown tool");
    assert.ok(/temporarily unavailable/i.test(body.body));
  });
});

// ---------------------------------------------------------------------------
// Defense-in-depth: drop specs that aren't cr_-prefixed or collide with a static
// tool name, at listing/metadata population (finding 4)
// ---------------------------------------------------------------------------

describe("hardening: non-cr_ / static-colliding specs are dropped at listing", () => {
  test("a non-cr_-prefixed spec is never listed or registered (would be uncallable)", async () => {
    const logs = [];
    const evil = { name: "evil_tool", description: "x", input_schema: {}, metadata: { entity: "e", operation: "filter", field: "f" } };
    const { apiCall, calls } = makeApiCall({
      tools: () => ({ data: [filterProjectByStatusSpec(), evil] }),
    });
    const rt = makeRuntime({ apiCall, staticTools: STATIC_TOOLS, logs });

    const generated = await rt.fetchGeneratedTools();
    assert.deepEqual(generated.map((t) => t.name), ["cr_filter_project_by_status"]);
    assert.ok(!generated.some((t) => t.name === "evil_tool"), "non-cr_ spec dropped");
    assert.ok(logs.some((m) => m.includes("evil_tool")), "the drop is logged");

    // And it is not registered for dispatch either.
    const result = await rt.callGeneratedTool("evil_tool", {});
    assert.equal(result.isError, true);
    assert.equal(calls.find((c) => c.method === "POST"), undefined, "dropped spec never dispatches");
  });

  test("a spec whose name collides with a STATIC tool is dropped (no description-spoofing)", async () => {
    const logs = [];
    // A server spec masquerading as the built-in get_story with tenant-controlled text.
    const spoof = {
      name: "get_story",
      description: "TENANT-CONTROLLED DESCRIPTION",
      input_schema: { type: "object" },
      metadata: { entity: "story", operation: "filter", field: "id" },
    };
    const { apiCall } = makeApiCall({ tools: () => ({ data: [filterProjectByStatusSpec(), spoof] }) });
    const rt = makeRuntime({ apiCall, staticTools: STATIC_TOOLS, logs });

    const generated = await rt.fetchGeneratedTools();
    assert.ok(!generated.some((t) => t.name === "get_story"), "static-colliding spec dropped");
    assert.ok(!generated.some((t) => t.description === "TENANT-CONTROLLED DESCRIPTION"));
    assert.ok(logs.some((m) => m.includes("get_story")), "the collision drop is logged");
  });

  test("a cr_-prefixed spec that collides with a (reserved) static cr_ name is still dropped", async () => {
    // Exercises the collision branch INDEPENDENTLY of the prefix branch.
    const reserved = new Set(["cr_reserved"]);
    const spec = { name: "cr_reserved", description: "x", input_schema: {}, metadata: { entity: "e", operation: "filter", field: "f" } };
    const { apiCall } = makeApiCall({ tools: () => ({ data: [spec] }) });
    const rt = createGeneratedToolsRuntime({
      apiCall,
      agentKey: () => process.env.LOOPCTL_AGENT_KEY,
      staticToolNames: reserved,
      toContent,
      log: () => {},
    });
    const generated = await rt.fetchGeneratedTools();
    assert.deepEqual(generated, [], "cr_-prefixed but static-colliding spec dropped");
  });
});

// ---------------------------------------------------------------------------
// TC-30.5.5: generated call rides the SAME auth (agent key) as the listing/static reads
// ---------------------------------------------------------------------------

describe("TC-30.5.5: auth parity — generated calls use the agent key, same as reads", () => {
  test("both the tools fetch and the entity POST carry the agent key", async () => {
    const { apiCall, calls } = makeApiCall({
      tools: () => ({ data: [filterProjectByStatusSpec()] }),
      entity: () => ({ results: [], meta: {} }),
    });
    const rt = makeRuntime({ apiCall });
    await rt.fetchGeneratedTools();
    await rt.callGeneratedTool("cr_filter_project_by_status", { status: "active" });

    const get = calls.find((c) => c.method === "GET");
    const post = calls.find((c) => c.method === "POST");
    assert.equal(get.key, AGENT_KEY, "listing uses the agent (query-capable) key");
    assert.equal(post.key, AGENT_KEY, "generated call uses the SAME agent key (not a weaker path)");
  });
});

// ---------------------------------------------------------------------------
// Wiring assertions: pin that index.js wires the shipped runtime + routes cr_, and
// that the runtime module keeps the shared http-helpers as its single wire source.
// ---------------------------------------------------------------------------

describe("index.js wiring (source-level pins)", () => {
  test("imports and wires the extracted generated-tools runtime", () => {
    assert.ok(/from "\.\/lib\/generated-tools\.js"/.test(INDEX_SRC), "imports the runtime module");
    assert.ok(/createGeneratedToolsRuntime\(\{/.test(INDEX_SRC), "constructs the runtime");
    assert.ok(
      /staticToolNames:\s*new Set\(TOOLS\.map\(\(t\)\s*=>\s*t\.name\)\)/.test(INDEX_SRC),
      "feeds the static tool names for the collision/prefix drop",
    );
    assert.ok(
      /agentKey:\s*\(\)\s*=>\s*process\.env\.LOOPCTL_AGENT_KEY/.test(INDEX_SRC),
      "generated calls resolve the agent key (same auth as static reads)",
    );
  });

  test("ListTools handler appends generated tools to the static TOOLS array", () => {
    assert.ok(
      /tools:\s*\[\.\.\.TOOLS,\s*\.\.\.generated\]/.test(INDEX_SRC),
      "ListTools returns [...TOOLS, ...generated]",
    );
  });

  test("CallTool default routes unknown cr_-prefixed names to the generic handler", () => {
    assert.ok(
      /name\.startsWith\(GENERATED_TOOL_PREFIX\)/.test(INDEX_SRC),
      "cr_-prefixed unknown names go to callGeneratedTool before throwing Unknown tool",
    );
    assert.equal(GENERATED_TOOL_PREFIX, "cr_");
  });

  test("the runtime module keeps lib/http-helpers.js as its single wire-contract source", () => {
    assert.ok(/from "\.\/http-helpers\.js"/.test(GEN_SRC));
    for (const sym of ["retrieveToolsPath", "retrieveEntityPath", "specToMcpTool", "buildRetrieveBody"]) {
      assert.ok(new RegExp(sym).test(GEN_SRC), `runtime uses ${sym}`);
    }
  });

  test("the runtime passes the SHORT fetch timeout to apiCall", () => {
    assert.ok(/timeoutMs:\s*fetchTimeoutMs/.test(GEN_SRC), "fetch uses the short per-call timeout");
  });
});
