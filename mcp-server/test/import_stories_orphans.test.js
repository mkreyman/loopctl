/**
 * `import_stories` reads `merge` and `report_orphans` as the server does (loopctl #880): true
 * or false only, and `report_orphans` only on a merge. Anything else is refused, never sent.
 *
 * Run: node --test test/*.test.js
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { importPath, importPayloadRefusal, importRefusal } from "../lib/http-helpers.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const P = "2b124878-8d23-412e-b421-992dece8ec96";
const BASE = `/api/v1/projects/${P}/import`;

test("true and false, as booleans or strings, build the path", () => {
  for (const [args, path] of [
    [{}, BASE],
    [{ merge: false }, BASE],
    [{ merge: "true" }, `${BASE}?merge=true`],
    [{ merge: true, report_orphans: "false" }, `${BASE}?merge=true`],
    [{ merge: true, report_orphans: true }, `${BASE}?merge=true&report_orphans=true`],
  ]) {
    assert.equal(importRefusal(args), null, JSON.stringify(args));
    assert.equal(importPath(P, args), path);
  }
});

test("any other value, or report_orphans without merge, is refused rather than dropped", () => {
  for (const args of [
    { merge: 1 },
    { merge: "yes" },
    { merge: true, report_orphans: 1 },
    { merge: true, report_orphans: "True" },
    { report_orphans: true },
  ]) {
    assert.ok(importRefusal(args), JSON.stringify(args));
  }
});

test("the project id is encoded, so it cannot rewrite the query", () => {
  assert.equal(importPath("a?merge=true", {}), "/api/v1/projects/a%3Fmerge%3Dtrue/import");
});

test("a payload carrying its own flags is refused: the server would read them too", () => {
  assert.ok(importPayloadRefusal({ epics: [], merge: false }));
  assert.ok(importPayloadRefusal({ epics: [], report_orphans: true }));
  assert.equal(importPayloadRefusal({ epics: [] }), null);
});

test("import_stories wires both refusals and declares the flag", () => {
  const start = INDEX_SRC.indexOf("async function importStories(");
  assert.ok(start >= 0);
  const end = INDEX_SRC.indexOf("\n}\n", start);
  assert.ok(end > start);
  const body = INDEX_SRC.slice(start, end);

  // The argument check runs before the payload file is read, and the payload is checked too.
  assert.ok(body.indexOf("importRefusal(") < body.indexOf("resolvePayload("));
  assert.ok(body.includes("importPayloadRefusal(effectivePayload)"));
  assert.ok(body.includes("if (payloadRefused) return toContent({ error: true"));
  assert.ok(body.includes("importPath(project_id, { merge, report_orphans })"));

  const decl = INDEX_SRC.indexOf('name: "import_stories"');
  assert.match(INDEX_SRC.slice(decl, INDEX_SRC.indexOf("required:", decl)), /report_orphans: \{/);
});
