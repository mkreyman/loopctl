/**
 * `import_stories` asks a merge for `stories_orphaned` only when told to (loopctl #880).
 *
 * Run: node --test test/*.test.js
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { importPath } from "../lib/http-helpers.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const P = "2b124878-8d23-412e-b421-992dece8ec96";

test("report_orphans reaches only a merge, and only as a real true", () => {
  assert.equal(importPath(P, {}), `/api/v1/projects/${P}/import`);
  assert.equal(importPath(P, { merge: true }), `/api/v1/projects/${P}/import?merge=true`);
  assert.equal(
    importPath(P, { merge: true, report_orphans: true }),
    `/api/v1/projects/${P}/import?merge=true&report_orphans=true`,
  );
  assert.equal(
    importPath(P, { merge: "true", report_orphans: "true" }),
    `/api/v1/projects/${P}/import?merge=true&report_orphans=true`,
  );

  // A non-boolean the server passed through unchecked must not turn the list on.
  for (const report_orphans of ["false", "yes", 1, false]) {
    assert.equal(
      importPath(P, { merge: true, report_orphans }),
      `/api/v1/projects/${P}/import?merge=true`,
    );
  }

  // Not a merge: the flag means nothing and is not sent.
  assert.equal(importPath(P, { report_orphans: true }), `/api/v1/projects/${P}/import`);
});

test("import_stories builds its path with importPath and declares the flag", () => {
  const start = INDEX_SRC.indexOf("async function importStories(");
  assert.ok(start >= 0);
  const end = INDEX_SRC.indexOf("\n}\n", start);
  assert.ok(end > start);
  assert.match(INDEX_SRC.slice(start, end), /importPath\(project_id, \{ merge, report_orphans \}\)/);

  const decl = INDEX_SRC.indexOf('name: "import_stories"');
  const schema = INDEX_SRC.slice(decl, INDEX_SRC.indexOf("required:", decl));
  assert.match(schema, /report_orphans: \{/);
  assert.match(schema, /ONLY with `report_orphans: true`/);
});
