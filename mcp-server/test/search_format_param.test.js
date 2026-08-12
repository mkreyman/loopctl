/**
 * `knowledge_search` gained a `format` parameter (loopctl#678): one command, three response
 * shapes, dispatching to the same progressive_index/3 and get_context/3 the sibling tools
 * call. The siblings are NOT retired.
 *
 * Asserted against the index.js SOURCE rather than through a re-implemented helper. The
 * other suites here re-implement handler bodies by design (index.js has top-level await and
 * exports nothing), but a re-implementation cannot catch the failure that matters for a
 * pass-through parameter: the schema advertising a field the request builder never forwards.
 * Reading the source is the only check that stays true when index.js changes.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const source = readFileSync(path.join(here, "..", "index.js"), "utf8");

describe("knowledge_search format parameter", () => {
  test("the request builder actually forwards it", () => {
    assert.match(
      source,
      /async function knowledgeSearch\(\{[^}]*\bformat\b[^}]*\}\)/,
      "knowledgeSearch must destructure `format`",
    );
    assert.match(
      source,
      /if \(format\) params\.set\("format", format\);/,
      "knowledgeSearch must forward `format` as a query param",
    );
  });

  test("the schema advertises exactly the shapes the server accepts", () => {
    const block = source.slice(source.indexOf('name: "knowledge_search"'));
    const formatProp = block.slice(block.indexOf("format: {"), block.indexOf("limit: {"));

    assert.ok(formatProp.includes("format: {"), "knowledge_search must declare `format`");
    for (const shape of ["results", "stubs", "bodies"]) {
      assert.ok(formatProp.includes(`"${shape}"`), `format enum must include ${shape}`);
    }
  });

  test("the description tells an agent the two ways it is refused", () => {
    const block = source.slice(source.indexOf('name: "knowledge_search"'));
    const formatProp = block.slice(block.indexOf("format: {"), block.indexOf("limit: {"));

    // Both are 400s on the server, and an agent that expects a silent downgrade to
    // `results` would misread an error as an empty corpus.
    assert.match(formatProp, /REQUIRE a query/, "must say stubs/bodies need a query");
    assert.match(formatProp, /never silently downgraded/, "must say an unknown value 400s");
  });

  test("it does not claim the sibling tools were removed", () => {
    const block = source.slice(source.indexOf('name: "knowledge_search"'));
    const formatProp = block.slice(block.indexOf("format: {"), block.indexOf("limit: {"));

    assert.match(formatProp, /both remain available/);
    assert.ok(
      source.includes('name: "knowledge_progressive_index"'),
      "knowledge_progressive_index must still be registered",
    );
    assert.ok(
      source.includes('name: "knowledge_context"'),
      "knowledge_context must still be registered",
    );
  });
});
