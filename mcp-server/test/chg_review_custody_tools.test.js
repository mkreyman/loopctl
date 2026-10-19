/**
 * loopctl US-47.5 on the MCP side: review custody for chg-dispatched reviews.
 *
 * - `review_complete` declares `commit_sha` and its handler FORWARDS it (AC-47.5.2), so a chg
 *   reviewer can name the revision it reviewed through this server at all.
 * - Each custody tool's description states the refusal the endpoint now answers and when
 *   (CLAUDE.md: "say in the tool description what the endpoint REFUSES"), because a session
 *   reads the description instead of the controller.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { loadTools, stripComments } from "./tool-surface.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const TOOLS = loadTools();

function tool(name) {
  const found = TOOLS.find((t) => t.name === name);
  assert.ok(found, `tool ${name} is not declared`);
  return found;
}

// One top-level async function's source, bounded at the next one, comments stripped — so an
// assertion cannot pass on a later function's body or on commented-out wiring.
function functionSource(name) {
  const declaration = `async function ${name}(`;
  const start = INDEX_SRC.indexOf(declaration);
  assert.notEqual(start, -1, `index.js must define ${declaration}`);
  const rest = INDEX_SRC.slice(start + declaration.length);
  const next = rest.indexOf("\nasync function ");
  return stripComments(next === -1 ? rest : rest.slice(0, next));
}

describe("review_complete carries commit_sha (AC-47.5.2)", () => {
  test("the schema declares it, optional, as a string", () => {
    const schema = tool("review_complete").inputSchema;
    assert.equal(schema.properties.commit_sha.type, "string");
    assert.ok(!schema.required.includes("commit_sha"), "commit_sha is required only server-side");
    assert.match(schema.properties.commit_sha.description, /REQUIRED on a story bound to a chg change/);
  });

  test("the handler destructures it and puts it in the request body", () => {
    const src = functionSource("reviewComplete");
    assert.match(src, /^\{[^}]*\bcommit_sha\b[^}]*\}/, "reviewComplete must take commit_sha");
    assert.match(src, /body\.commit_sha\s*=\s*commit_sha/, "reviewComplete must forward commit_sha");
  });
});

describe("descriptions name the US-47.5 refusals", () => {
  test("review_complete: chg_reviewer_required, commit_sha_not_bound, chg_review_already_recorded", () => {
    const d = tool("review_complete").description;
    assert.match(d, /409 chg_reviewer_required/);
    assert.match(d, /422 commit_sha_not_bound/);
    assert.match(d, /409 chg_review_already_recorded/);
    assert.match(d, /commit_sha is REQUIRED/);
    // The new gates are additive; the description must not read as replacing the old ones.
    assert.match(d, /never instead of them/);
  });

  for (const name of ["verify_story", "reject_story", "verify_all_in_epic", "bulk_mark_complete"]) {
    test(`${name}: 409 chg_root_cannot_verify`, () => {
      assert.match(tool(name).description, /409 chg_root_cannot_verify/);
    });
  }

  for (const name of ["claim_story", "report_story"]) {
    test(`${name}: 409 chg_root_review_only`, () => {
      assert.match(tool(name).description, /409 chg_root_review_only/);
    });
  }
});
