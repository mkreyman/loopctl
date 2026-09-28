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

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");

test("report_orphans is declared and reaches the merge query string", () => {
  const start = INDEX_SRC.indexOf("async function importStories(");
  const body = INDEX_SRC.slice(start, INDEX_SRC.indexOf("\n}\n", start));

  assert.match(body, /report_orphans \? "\?merge=true&report_orphans=true" : "\?merge=true"/);

  const decl = INDEX_SRC.indexOf('name: "import_stories"');
  const schema = INDEX_SRC.slice(decl, INDEX_SRC.indexOf("required:", decl));
  assert.match(schema, /report_orphans: \{/);
});
