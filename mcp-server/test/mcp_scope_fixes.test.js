/**
 * Regression tests for mcp-01, mcp-02, mcp-03 scope fixes
 *
 * - mcp-01: Unwired tools (all verified wired during audit)
 * - mcp-02: Schema validation gaps (enum, minLength/maxLength, oneOf)
 * - mcp-03: BYPASSRLS tenant-safety assertions
 *
 * Uses Node.js built-in test runner (node:test). Run: npm test
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const indexPath = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "index.js",
);

describe("mcp-02: Schema validation gaps", () => {
  const src = readFileSync(indexPath, "utf8");

  test("review_complete.review_type has enum constraint", () => {
    const toolMatch = src.match(
      /name: "review_complete"[\s\S]*?inputSchema:\s*\{[\s\S]*?review_type:\s*\{([^}]+)\}/,
    );
    assert.ok(toolMatch, "review_complete tool definition found");
    const schemaSnip = toolMatch[1];
    assert.ok(
      /enum:\s*\["enhanced_6_agent",\s*"single_reviewer",\s*"orchestrator"\]/.test(
        schemaSnip,
      ),
      "review_type field must have enum constraint for valid review types",
    );
  });

  test("create_project.name has minLength and maxLength constraints", () => {
    const toolMatch = src.match(
      /name: "create_project"[\s\S]*?inputSchema:\s*\{[\s\S]*?properties:\s*\{[\s\S]*?name:\s*\{([^}]+)\}/,
    );
    assert.ok(toolMatch, "create_project tool definition found");
    const schemaSnip = toolMatch[1];
    assert.ok(
      /minLength:\s*1/.test(schemaSnip),
      "name field must have minLength: 1",
    );
    assert.ok(
      /maxLength:\s*255/.test(schemaSnip),
      "name field must have maxLength: 255",
    );
  });

  test("knowledge_ingest has oneOf constraint for url/content mutual exclusivity", () => {
    const toolMatch = src.match(
      /name: "knowledge_ingest"[\s\S]*?inputSchema:([\s\S]*?),\n\s*\},\n\s*\{/,
    );
    assert.ok(toolMatch, "knowledge_ingest tool definition found");
    const schemaSnip = toolMatch[1];
    assert.ok(
      /oneOf/.test(schemaSnip),
      "knowledge_ingest inputSchema must have oneOf constraint",
    );
    assert.ok(
      /required:\s*\["source_type",\s*"url"\]/.test(schemaSnip),
      "oneOf must require source_type + url",
    );
    assert.ok(
      /required:\s*\["source_type",\s*"content"\]/.test(schemaSnip),
      "oneOf must require source_type + content",
    );
  });
});

describe("mcp-03: Tenant-safety warnings and assertions", () => {
  const src = readFileSync(indexPath, "utf8");

  test("get_sth has TENANT SAFETY warning in description", () => {
    const toolMatch = src.match(
      /name: "get_sth"[\s\S]*?description:([\s\S]*?)inputSchema/,
    );
    assert.ok(toolMatch, "get_sth tool definition found");
    const desc = toolMatch[1];
    assert.ok(
      /WARNING|TENANT SAFETY/.test(desc),
      "get_sth description must have WARNING or TENANT SAFETY",
    );
    assert.ok(
      /cross-tenant/.test(desc),
      "get_sth description must warn about cross-tenant issues",
    );
  });

  test("get_sth handler has tenant-safety assertion comment", () => {
    const fnMatch = src.match(
      /\/\/ TENANT SAFETY.*?async function getSth/s,
    );
    assert.ok(fnMatch, "getSth handler must have TENANT SAFETY comment before function");
  });

  test("recover_cap has SECURITY/TENANT warning in description", () => {
    const toolMatch = src.match(
      /name: "recover_cap",\s*description:\s*"([^"]+)"(?:\s*\+\s*"([^"]+)")?/,
    );
    assert.ok(toolMatch, "recover_cap tool definition found");
    const desc = (toolMatch[1] || "") + (toolMatch[2] || "");
    assert.ok(
      /SECURITY|tenant.*context|cross-tenant/.test(desc),
      "recover_cap description must warn about tenant context validation",
    );
  });

  test("recover_cap handler has tenant-safety assertion comment", () => {
    const fnMatch = src.match(
      /\/\/ TENANT SAFETY.*?async function recoverCap/s,
    );
    assert.ok(fnMatch, "recoverCap handler must have TENANT SAFETY comment before function");
  });

  test("recover_cap.story_id has tenant context requirement in description", () => {
    const toolMatch = src.match(
      /name: "recover_cap"[\s\S]*?inputSchema:[\s\S]*?story_id:\s*\{\s*type:\s*"string",\s*description:\s*"([^"]+)"/,
    );
    assert.ok(toolMatch, "recover_cap.story_id property found");
    const desc = toolMatch[1];
    assert.ok(
      /tenant.*context|MUST belong to your tenant/.test(desc),
      "recover_cap story_id field description must mention tenant context requirement",
    );
  });

  test("get_sth.tenant_id has tenant context requirement in description", () => {
    const toolMatch = src.match(
      /name: "get_sth"[\s\S]*?inputSchema:[\s\S]*?tenant_id:\s*\{\s*type:\s*"string",\s*description:\s*"([^"]+)"/,
    );
    assert.ok(toolMatch, "get_sth.tenant_id property found");
    const desc = toolMatch[1];
    assert.ok(
      /MUST match|caller.*tenant/.test(desc),
      "get_sth tenant_id field description must mention that it must match caller's tenant",
    );
  });
});

describe("mcp-01: All tools wired (regression check)", () => {
  const src = readFileSync(indexPath, "utf8");

  test("All 69 tools have corresponding case statements in switch", () => {
    // Extract tool names from TOOLS array
    const toolNames = new Set();
    const toolMatches = src.matchAll(/name:\s*"([^"]+)"/g);
    for (const match of toolMatches) {
      if (match[1] !== "loopctl") { // Skip server name
        toolNames.add(match[1]);
      }
    }

    // Extract case statement names
    const caseNames = new Set();
    const caseMatches = src.matchAll(/case\s*"([^"]+)":/g);
    for (const match of caseMatches) {
      caseNames.add(match[1]);
    }

    // Verify each tool has a case
    const missing = [];
    for (const name of toolNames) {
      if (!caseNames.has(name)) {
        missing.push(name);
      }
    }

    assert.equal(
      missing.length,
      0,
      `All tools must have case statements in the switch. Missing: ${missing.join(", ")}`,
    );
  });
});
