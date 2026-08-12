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

test("an UNOBSERVED spelling is deliberately NOT aliased", () => {
  // The table carries only what agents were measured to send. `text` in particular must
  // never map to `q`: memory_remember declares it for a memory's CONTENT.
  assert.equal(applyArgAliases({ text: "a fact worth remembering" }).q, undefined);
  assert.equal(applyArgAliases({ articleId: "abc" }).article_id, undefined);
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

// ---------------------------------------------------------------------------------------
// Data-driven regression: the SIX distinct input shapes that actually produced
// `400 Query parameter 'q' is required` in the transcripts. Encoded verbatim rather than
// paraphrased, so this asserts against measured reality instead of against my model of it.
// Counts are the observed frequency of each shape.
// ---------------------------------------------------------------------------------------
const OBSERVED_FAILING_SHAPES = [
  { count: 42, keys: "max_results,query", input: { query: "fail-open bounded allowance backpressure exit throw classification", max_results: "6" } },
  { count: 29, keys: "query", input: { query: "idempotency tag namespace collision url- sha1 knowledge article tags" } },
  { count: 10, keys: "project_id,query", input: { query: "custody halt tenant threshold byzantine detection", project_id: "a40edb79-d290-475f-9bdb-6e6c5458af97" } },
  { count: 3, keys: "limit,query", input: { query: "catalog probe search_path current_schemas version skew", limit: 8 } },
  { count: 1, keys: "args,max_results,query", input: { query: "LCP-1 signed custody profile attestation enrollment owner key", max_results: "8", args: {} } },
];

test("every observed failing shape now yields a usable q", () => {
  for (const shape of OBSERVED_FAILING_SHAPES) {
    const out = applyArgAliases(shape.input);
    assert.ok(
      typeof out.q === "string" && out.q.length > 0,
      `shape {${shape.keys}} (${shape.count} real calls) must produce a q, got ${JSON.stringify(out.q)}`,
    );
  }
});

test("the one shape that carried NO query in any spelling is still not invented", () => {
  // 1 of the 86 genuinely passed no query. Aliasing must not fabricate one — that call
  // was a real caller bug and should still be rejected loudly.
  const out = applyArgAliases({ max_results: "1" });
  assert.equal(out.q, undefined);
  assert.equal(out.limit, 1);
});

test("BOTH spellings work, in both directions — the surface is inconsistent by history", () => {
  // knowledge_search declares `q`; knowledge_hybrid_search / knowledge_context /
  // memory_recall / recall_context all declare `query`. Either spelling must reach either
  // family, or an agent that learned one from a sibling tool loses its search.
  const fromQuery = applyArgAliases({ query: "vector recall degraded fallback" });
  assert.equal(fromQuery.q, "vector recall degraded fallback", "query must fill q");
  assert.equal(fromQuery.query, "vector recall degraded fallback", "query must survive");

  const fromQ = applyArgAliases({ q: "vector recall degraded fallback" });
  assert.equal(fromQ.query, "vector recall degraded fallback", "q must fill query");
  assert.equal(fromQ.q, "vector recall degraded fallback", "q must survive");

  // `max_results` is one-way ONLY: it fills `limit`, never the reverse. No tool declares
  // `max_results`, so filling it rescued nothing and only put a spurious "rescue" on every
  // correctly-paginated call.
  const limits = applyArgAliases({ q: "x", limit: 5 });
  assert.equal(limits.limit, 5);
  assert.equal(limits.max_results, undefined, "limit must NOT invent a max_results");
});

test("a rescue is counted only when the CALLED TOOL declares the key it filled", () => {
  // The metric exists to price the residual inconsistency, so it must count calls that
  // WOULD HAVE FAILED. A correct knowledge_search call carrying `q` still fills `query`
  // (inert), and counting that made normal traffic the bulk of the "rescues".
  const correct = [];
  applyArgAliases({ q: "already correct" }, (pair) => correct.push(pair), ["q", "limit"]);
  assert.deepEqual(correct, [], "a correctly-spelled call is not a rescue");

  const rescued = [];
  applyArgAliases({ query: "wrong spelling" }, (pair) => rescued.push(pair), ["q", "limit"]);
  assert.deepEqual(rescued, [{ canonical: "q", alias: "query" }]);

  // Mirror image: for a tool that declares `query`, arriving with `q` is the rescue.
  const mirrored = [];
  applyArgAliases({ q: "wrong spelling" }, (pair) => mirrored.push(pair), ["query"]);
  assert.deepEqual(mirrored, [{ canonical: "query", alias: "q" }]);
});

test("WIRING: the dispatch passes the called tool's declared parameters", () => {
  // Without this argument the gate above is inert in production — the exact shape of
  // failure (correct logic nothing calls) this investigation started from.
  const src = readFileSync(join(here, "..", "index.js"), "utf8");
  assert.match(src, /declaredToolArgs\(name\),/);
  assert.match(src, /DECLARED_TOOL_ARGS = new Map\(/);
});

test("the alias callback fires with the pair, so the rescue stays measurable", () => {
  // Aliasing treats the symptom; the disease is three spellings for one parameter. If the
  // rescue is invisible it costs nothing measurable and never gets fixed.
  const seen = [];
  applyArgAliases({ query: "x", max_results: "3" }, (pair) => seen.push(pair));

  assert.deepEqual(seen.sort((a, b) => a.canonical.localeCompare(b.canonical)), [
    { canonical: "limit", alias: "max_results" },
    { canonical: "q", alias: "query" },
  ]);
});

test("a throwing callback never breaks the tool call", () => {
  const out = applyArgAliases({ query: "still works" }, () => {
    throw new Error("telemetry exploded");
  });

  assert.equal(out.q, "still works");
});

test("no callback is required", () => {
  assert.equal(applyArgAliases({ query: "x" }).q, "x");
});

test("SCHEMA DRIFT GUARD: no CURRENT alias silently shadows a real tool parameter", async () => {
  // The invariant: for every alias name the table maps FROM, no tool may declare that name
  // as its own parameter — unless the pair is deliberately bidirectional (q <-> query,
  // limit <-> max_results), where both names are canonical for different tools and filling
  // one from the other is the entire point.
  //
  // This guard has already earned its keep twice, on the change that introduced it: it
  // caught `query` (canonical for four tools) and `text` (memory_remember's memory CONTENT)
  // being mapped into `q`. Both were speculative aliases with no support in the data.
  const src = readFileSync(join(here, "..", "index.js"), "utf8");
  const { ARG_ALIASES } = await import("../lib/arg-aliases.js");

  const bidirectional = new Set(["q", "query", "limit", "max_results"]);
  const aliasNames = new Set(Object.values(ARG_ALIASES).flat());

  for (const alias of aliasNames) {
    if (bidirectional.has(alias)) continue;
    const declared = new RegExp(`^\\s{6,}${alias}:\\s*\\{\\s*$`, "m").test(src);
    assert.ok(
      !declared,
      `'${alias}' is in ARG_ALIASES but a tool declares it as its own parameter — aliasing ` +
        `it would silently rename that tool's argument. Remove the alias, or make it ` +
        `tool-scoped, or add it to the deliberate bidirectional set.`,
    );
  }
});

test("the bidirectional pair really is canonical on BOTH sides (not a rationalisation)", () => {
  // If knowledge_search ever stops declaring `q`, or the `query` family disappears, the
  // bidirectional exemption above becomes an unexamined hole. Pin both halves.
  const src = readFileSync(join(here, "..", "index.js"), "utf8");
  assert.match(src, /^\s{6,}q:\s*\{\s*$/m, "expected some tool to declare `q`");
  assert.match(src, /^\s{6,}query:\s*\{\s*$/m, "expected some tool to declare `query`");
});

test("WIRING: index.js applies the aliases at the CallTool dispatch point", () => {
  const src = readFileSync(join(here, "..", "index.js"), "utf8");
  assert.match(src, /import \{ applyArgAliases \} from "\.\/lib\/arg-aliases\.js";/);
  // The dispatch must alias the incoming arguments, not read request.params.arguments raw.
  // Matches the call regardless of whether a telemetry callback is passed, but still
  // pins that the DISPATCH ARGUMENTS are what gets aliased.
  assert.match(src, /const args = applyArgAliases\(\s*request\.params\.arguments/);
  assert.doesNotMatch(
    src,
    /const \{ name, arguments: args \} = request\.params;/,
    "dispatch must not bypass aliasing by destructuring arguments directly",
  );
});
