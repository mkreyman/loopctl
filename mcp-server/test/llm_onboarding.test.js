/**
 * Tests for the smooth agent BYO-LLM onboarding experience:
 *  - set_llm_config / llm_config tool descriptions fully onboard a stranger agent
 *  - ingest/search tool RESULTS surface the server's remediation prominently
 *  - README carries the first-time-setup walkthrough
 *
 * Uses Node.js built-in test runner (node:test). Run: node --test test/
 *
 * The handler helpers in index.js are not exported (server entry point with
 * top-level await), so — per the existing test convention (knowledge_tools.test.js)
 * — we re-implement the minimal helpers under test here, mirroring index.js exactly,
 * and read index.js / README.md as text for the description assertions.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const indexPath = path.join(__dirname, "..", "index.js");
const readmePath = path.join(__dirname, "..", "README.md");

// ---------------------------------------------------------------------------
// Minimal re-implementation of the helpers under test (mirror index.js exactly)
// ---------------------------------------------------------------------------

function toContent(result) {
  const isErr = result && result.error === true;
  return {
    content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    ...(isErr && { isError: true }),
  };
}

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

// Server-shaped fixtures (match lib/loopctl/llm/remediation.ex).
const ANTHROPIC_REMEDIATION = {
  action: "configure_llm",
  missing: ["api_key"],
  credential: "anthropic_api_key",
  mcp_tool: "set_llm_config",
  example: 'set_llm_config({"api_key": "<your Anthropic API key>"})',
  api: "PATCH /api/v1/tenants/me/llm-config",
  docs: "https://loopctl.com/wiki/agent-onboarding",
  message: "This tenant has no Anthropic API key configured.",
};

const EMBEDDING_REMEDIATION = {
  ...ANTHROPIC_REMEDIATION,
  missing: ["embedding_api_key"],
  credential: "openai_embedding_api_key",
  example: 'set_llm_config({"embedding_api_key": "<your OpenAI API key>"})',
  message: "Semantic ranking is unavailable because this tenant has no embedding API key.",
};

// ---------------------------------------------------------------------------

describe("set_llm_config / llm_config tool descriptions onboard a stranger agent", () => {
  const source = readFileSync(indexPath, "utf8");

  // Isolate each tool block so assertions target the right description.
  // Slice to the START OF THE NEXT tool declaration rather than a fixed byte
  // window: a fixed window silently truncates the block as a tool's description /
  // schema grows (US-41.3 added four chat-endpoint params), turning a real
  // assertion into a false failure about text that IS present, just past the cut.
  function toolBlock(name) {
    const marker = `name: "${name}"`;
    const start = source.indexOf(marker);
    assert.ok(start !== -1, `tool ${name} should be defined`);
    const next = source.indexOf('\n    name: "', start + marker.length);
    return next === -1 ? source.slice(start) : source.slice(start, next);
  }

  test("set_llm_config explains WHAT / WHY / WHEN / the required user key", () => {
    const block = toolBlock("set_llm_config");
    assert.match(block, /FIRST-TIME SETUP/);
    assert.match(block, /BYO/);
    assert.match(block, /Anthropic/);
    assert.match(block, /embedding/i);
    assert.match(block, /encrypted/);
    assert.match(block, /LOOPCTL_USER_KEY/);
    assert.match(block, /partial-merge/);
    // Both credential params are documented with what they power.
    assert.match(block, /api_key/);
    assert.match(block, /embedding_api_key/);
  });

  test("llm_config advertises has_api_key / has_embedding_key as a setup check", () => {
    const block = toolBlock("llm_config");
    assert.match(block, /has_api_key/);
    assert.match(block, /has_embedding_key/);
    assert.match(block, /LOOPCTL_USER_KEY/);
  });
});

describe("ingest/search results surface the BYO remediation prominently", () => {
  test("ingest no-key 422 leads with an ACTION REQUIRED notice naming set_llm_config", () => {
    const result = {
      error: true,
      status: 422,
      body: { error: { status: 422, code: "no_api_key", message: "x", remediation: ANTHROPIC_REMEDIATION } },
    };
    const out = withRemediationNotice(result);

    const lead = out.content[0].text;
    assert.match(lead, /ACTION REQUIRED/);
    assert.match(lead, /set_llm_config/);
    assert.match(lead, /api_key/);
    assert.match(lead, /LOOPCTL_USER_KEY/);
    // isError is preserved so the caller still sees it failed.
    assert.equal(out.isError, true);
    // The raw JSON body is still present after the notice.
    assert.ok(out.content.length >= 2);
  });

  test("search keyword-only degrade leads with the embedding-key remediation", () => {
    const result = {
      data: [],
      meta: {
        fallback: true,
        search_mode: "keyword_only",
        fallback_reason: "no_embedding_key",
        remediation: EMBEDDING_REMEDIATION,
      },
    };
    const out = withRemediationNotice(result);

    const lead = out.content[0].text;
    assert.match(lead, /ACTION REQUIRED/);
    assert.match(lead, /set_llm_config/);
    assert.match(lead, /embedding_api_key/);
    // A 200 degrade is not an error.
    assert.equal(out.isError, undefined);
  });

  test("a normal result surfaces NO notice (no false positives)", () => {
    const result = { data: [{ id: "a" }], meta: { total_count: 1, search_mode: "combined" } };
    const out = withRemediationNotice(result);
    assert.equal(out.content.length, 1);
    assert.doesNotMatch(out.content[0].text, /ACTION REQUIRED/);
  });

  test("a non-LLM error (learn_more shape) surfaces NO llm notice", () => {
    const result = {
      error: true,
      status: 409,
      body: { error: { code: "self_verify_blocked", remediation: { learn_more: "https://x" } } },
    };
    assert.equal(llmRemediationNotice(result), null);
  });
});

describe("README carries the first-time-setup walkthrough", () => {
  const readme = readFileSync(readmePath, "utf8");

  test("has a First-time setup section with the smooth path", () => {
    assert.match(readme, /First-time setup — provision your BYO LLM keys/);
    assert.match(readme, /set_llm_config\(\{ api_key/);
    assert.match(readme, /embedding_api_key/);
    assert.match(readme, /LOOPCTL_USER_KEY/);
  });

  test("tool table mentions BOTH the Anthropic and embedding keys for set_llm_config", () => {
    assert.match(readme, /Anthropic `api_key`/);
    assert.match(readme, /OpenAI `embedding_api_key`/);
  });
});
