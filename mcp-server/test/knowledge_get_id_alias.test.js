/**
 * knowledge_get (and its two sibling reads) accept the `id` spelling agents send, and a
 * request with an unfilled path argument is refused before it is sent.
 *
 * Measured 2026-10-01: all 30 knowledge_get 404s in loopctl's production logs for
 * 2026-09-25..30 were `GET /api/v1/articles/undefined` (38 of 38 reads carrying a real id
 * succeeded), and 17 of 96 knowledge_get calls in mac-mini's transcripts passed
 * `{"id": ...}`. Agents read the 404 as "the article is gone".
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { applyArgAliases, TOOL_SCOPED_ALIASES } from "../lib/arg-aliases.js";
import { unfilledPathRefusal } from "../lib/path-guard.js";
import { loadTools, stripComments } from "./tool-surface.js";

const here = dirname(fileURLToPath(import.meta.url));
const SRC = stripComments(readFileSync(join(here, "..", "index.js"), "utf8"));
const DECLARED = new Map(loadTools().map((t) => [t.name, Object.keys(t.inputSchema.properties)]));
const UUID = "f7e1b841-4102-4e72-83bc-81cfe4a65129";

const call = (tool, args, seen) =>
  applyArgAliases(args, seen ? (p) => seen.push(p) : undefined, DECLARED.get(tool), tool);

test("the three reads rescue {id} into article_id, and report the rescue", () => {
  for (const tool of ["knowledge_get", "knowledge_progressive_drill", "knowledge_article_stats"]) {
    const seen = [];
    assert.equal(call(tool, { id: UUID }, seen).article_id, UUID, tool);
    assert.deepEqual(seen, [{ canonical: "article_id", alias: "id" }], tool);
  }
});

test("an explicit article_id wins over id", () => {
  assert.equal(call("knowledge_get", { article_id: UUID, id: "other" }).article_id, UUID);
});

test("write verbs never take id: a copied id cannot archive or delete anything", () => {
  for (const tool of ["knowledge_archive", "knowledge_delete", "knowledge_unpublish", "knowledge_update"]) {
    assert.ok(DECLARED.get(tool).includes("article_id"), tool);
    assert.equal(call(tool, { id: UUID }).article_id, undefined, tool);
  }
});

test("the alias needs the tool's schema, and never renames a tool's own id", () => {
  assert.equal(applyArgAliases({ id: UUID }, null, undefined, "knowledge_get").article_id, undefined);
  assert.equal(applyArgAliases({ id: UUID }, null, ["id", "article_id"], "knowledge_get").article_id, undefined);
  assert.equal(applyArgAliases({ id: UUID }, null, ["post_id"], "knowledge_get").article_id, undefined);
});

test("every TOOL_SCOPED_ALIASES key is a real tool declaring the canonical", () => {
  for (const [tool, map] of Object.entries(TOOL_SCOPED_ALIASES)) {
    assert.ok(DECLARED.has(tool), `${tool} is not a declared tool`);
    for (const canonical of Object.keys(map)) {
      assert.ok(DECLARED.get(tool).includes(canonical), `${tool} must declare ${canonical}`);
    }
  }
});

test("an unfilled path segment is refused locally; a filled one, or one in the query, is not", () => {
  for (const p of ["/api/v1/articles/undefined", "/api/v1/articles/undefined?links=none", "/api/v1/channel/posts/null"]) {
    const r = unfilledPathRefusal(p);
    assert.equal(r?.error, true, p);
    assert.equal(r.status, 0, p);
    assert.match(r.body, /never requested/);
    assert.match(r.body, /<missing>/);
  }
  assert.equal(unfilledPathRefusal(`/api/v1/articles/${UUID}`), null);
  assert.equal(unfilledPathRefusal("/api/v1/knowledge/search?q=undefined"), null);
  assert.equal(unfilledPathRefusal("/api/v1/articles/undefined-behaviour"), null);
});

test("WIRING: apiCall refuses before building the URL, and dispatch passes the tool name", () => {
  assert.match(
    SRC,
    /^\s*const unfilled = unfilledPathRefusal\(path\);\n\s*if \(unfilled\) return unfilled;\n\s*const url = `\$\{getBaseUrl\(\)\}\$\{path\}`;/m,
  );
  assert.match(SRC, /^\s*declaredToolArgs\(name\),\n\s*name,\n\s*\);/m);
});
