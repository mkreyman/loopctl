/**
 * Regression tests for MCP argument-name aliases (#657).
 *
 * The defect these prevent, measured rather than imagined: across 1,932 real agent searches
 * mined from session transcripts on two machines, 86 knowledge_search calls (8% of every
 * search made) failed with `400 Query parameter 'q' is required`, and 85 of them had passed
 * `query` instead of `q`. The queries were high quality; all were discarded on a synonym.
 *
 * SINGLE SOURCE OF TRUTH: the aliasing logic lives in ../lib/arg-aliases.js, imported by the
 * real server (index.js), so these tests exercise the exact code the server ships. The final
 * test pins the WIRING — that index.js actually applies it at the dispatch point — because
 * correct logic that nothing calls is the failure mode this whole investigation started from.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { applyArgAliases } from "../lib/arg-aliases.js";

const here = dirname(fileURLToPath(import.meta.url));

test("query is accepted as an alias for q — the exact 85-call failure", () => {
  const out = applyArgAliases({ query: "custody halt tenant threshold byzantine detection" });
  assert.equal(out.q, "custody halt tenant threshold byzantine detection");
});

test("max_results is accepted as an alias for limit, and coerced from a string", () => {
  const out = applyArgAliases({ query: "anything", max_results: "6" });
  assert.equal(out.limit, 6);
  assert.equal(typeof out.limit, "number");
});

test("the real-world shape from the transcripts round-trips", () => {
  // Verbatim from a failing call.
  const out = applyArgAliases({
    query: "LCP-1 signed custody profile attestation enrollment owner key",
    max_results: "8",
  });
  assert.equal(out.q, "LCP-1 signed custody profile attestation enrollment owner key");
  assert.equal(out.limit, 8);
});

test("an explicit canonical value always wins over an alias", () => {
  const out = applyArgAliases({ q: "canonical", query: "alias" });
  assert.equal(out.q, "canonical");
});

test("a blank canonical is filled from the alias (an empty q is not a choice)", () => {
  const out = applyArgAliases({ q: "", query: "real query" });
  assert.equal(out.q, "real query");
});

test("a blank alias does not overwrite or invent a canonical", () => {
  const out = applyArgAliases({ query: "" });
  assert.equal(out.q, undefined);
});

test("other canonical names alias too", () => {
  assert.equal(applyArgAliases({ articleId: "abc" }).article_id, "abc");
  assert.equal(applyArgAliases({ projectId: "p1" }).project_id, "p1");
  assert.equal(applyArgAliases({ sinceDays: 7 }).since_days, 7);
});

test("unrelated args are passed through untouched and the input is not mutated", () => {
  const input = { query: "x", mode: "combined", tags: ["a"] };
  const out = applyArgAliases(input);
  assert.equal(out.mode, "combined");
  assert.deepEqual(out.tags, ["a"]);
  assert.equal(input.q, undefined, "input object must not be mutated");
});

test("non-object input is returned unchanged rather than throwing", () => {
  assert.equal(applyArgAliases(undefined), undefined);
  assert.equal(applyArgAliases(null), null);
  const arr = [1, 2];
  assert.equal(applyArgAliases(arr), arr);
});

test("a non-numeric limit string is left alone rather than becoming NaN", () => {
  assert.equal(applyArgAliases({ q: "x", limit: "lots" }).limit, "lots");
});

test("WIRING: index.js applies the aliases at the CallTool dispatch point", () => {
  const src = readFileSync(join(here, "..", "index.js"), "utf8");
  assert.match(src, /import \{ applyArgAliases \} from "\.\/lib\/arg-aliases\.js";/);
  // The dispatch must alias the incoming arguments, not read request.params.arguments raw.
  assert.match(src, /const args = applyArgAliases\(request\.params\.arguments\);/);
  assert.doesNotMatch(
    src,
    /const \{ name, arguments: args \} = request\.params;/,
    "dispatch must not bypass aliasing by destructuring arguments directly",
  );
});
