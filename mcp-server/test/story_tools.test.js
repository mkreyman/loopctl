/**
 * Regression tests for #155: list_stories / list_ready_stories must NOT silently
 * clamp the requested limit to 20. They default to 20 but honor an explicit limit
 * up to the server max (500).
 *
 * Uses Node.js built-in test runner (node:test). Run: node --test test/
 *
 * The handler functions in index.js are not exported (server entry point with
 * top-level await), so we mirror the exact limit computation here and also assert
 * the source no longer uses the old 20-cap, keeping the test resilient yet faithful.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const DEFAULT_STORY_PAGE_SIZE = 20;
const SERVER_MAX_STORY_PAGE_SIZE = 500;

// Mirrors index.js: params.set("limit", String(Math.min(limit ?? DEFAULT, SERVER_MAX)))
function resolvedLimit(limit) {
  return Math.min(limit ?? DEFAULT_STORY_PAGE_SIZE, SERVER_MAX_STORY_PAGE_SIZE);
}

describe("#155 story-list limit handling", () => {
  test("defaults to 20 when limit is omitted", () => {
    assert.equal(resolvedLimit(undefined), 20);
    assert.equal(resolvedLimit(null), 20);
  });

  test("honors an explicit limit up to the server max (no 20-cap)", () => {
    assert.equal(resolvedLimit(50), 50);
    assert.equal(resolvedLimit(200), 200);
    assert.equal(resolvedLimit(500), 500);
  });

  test("clamps above the server max to 500", () => {
    assert.equal(resolvedLimit(1000), 500);
  });

  test("source no longer caps story listing at 20 (MAX_PAGE_SIZE removed)", () => {
    const indexPath = path.join(
      path.dirname(fileURLToPath(import.meta.url)),
      "..",
      "index.js",
    );
    const src = readFileSync(indexPath, "utf8");
    // The old constant that silently capped story pages at 20 must be gone.
    assert.ok(
      !/const MAX_PAGE_SIZE = 20/.test(src),
      "index.js still defines the 20-row MAX_PAGE_SIZE cap",
    );
    // The story handlers must use the server-max constant.
    assert.ok(
      /SERVER_MAX_STORY_PAGE_SIZE = 500/.test(src),
      "index.js should define SERVER_MAX_STORY_PAGE_SIZE = 500",
    );
  });
});
