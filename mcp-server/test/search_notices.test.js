/**
 * #658 — the degraded-search notice.
 *
 * Measured defect: the server discloses degradation loudly in `meta` (fallback,
 * degraded, fallback_reason, telemetry, warning log) and agents do not read `meta`. Every
 * degraded-and-empty response observed in real transcripts was treated as "the knowledge
 * base has nothing". Low volume, totally deceptive, and it lands hardest on the BEST
 * queries — the keyword fallback lane ANDs its terms, so a long specific query is the most
 * likely to match nothing even when the answer exists.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { degradedSearchNotice } from "../lib/search-notices.js";

const here = dirname(fileURLToPath(import.meta.url));

test("a healthy search gets no notice", () => {
  assert.equal(degradedSearchNotice({ data: [{ id: 1 }], meta: { search_mode: "combined" } }), null);
});

test("a genuine empty result gets NO notice — it really is a miss", () => {
  // The notice must not fire on an ordinary zero-result search, or it becomes noise that
  // teaches agents to ignore it — the exact fate of the meta fields it exists to replace.
  assert.equal(degradedSearchNotice({ data: [], meta: { search_mode: "combined" } }), null);
});

test("degraded AND empty says explicitly that this is not 'no results'", () => {
  const notice = degradedSearchNotice({
    data: [],
    meta: { fallback: true, degraded: true, fallback_reason: "embedding_timeout" },
  });

  assert.match(notice, /NOT "NO RESULTS"/);
  assert.match(notice, /embedding_timeout/, "the cause must be named");
  assert.match(notice, /RETRY THE SAME QUERY/);
});

test("it tells the agent NOT to rephrase — the counter-intuitive half", () => {
  // Rephrasing is the instinctive response to an empty result and it cannot work here:
  // different words do not fix a provider timeout. Getting this backwards wastes the
  // retry AND drifts the query away from the one that would have worked.
  const notice = degradedSearchNotice({
    data: [],
    meta: { fallback: true, fallback_reason: "embedding_provider_error_500" },
  });

  assert.match(notice, /do NOT rephrase/i);
});

test("degraded WITH results gets the softer 'may be incomplete' wording", () => {
  const notice = degradedSearchNotice({
    data: [{ id: 1 }],
    meta: { fallback: true, fallback_reason: "heavy_read_overloaded" },
  });

  assert.match(notice, /PARTIAL SEARCH/);
  assert.doesNotMatch(notice, /NOT "NO RESULTS"/);
  assert.match(notice, /heavy_read_overloaded/, "a non-embedding cause is still named");
});

test("the BYO-key case defers to its own more specific ACTION REQUIRED notice", () => {
  assert.equal(
    degradedSearchNotice({
      data: [],
      meta: { fallback: true, fallback_reason: "no_embedding_key" },
    }),
    null,
  );
});

test("malformed or absent results never throw", () => {
  assert.equal(degradedSearchNotice(undefined), null);
  assert.equal(degradedSearchNotice(null), null);
  assert.equal(degradedSearchNotice({}), null);
  // A degraded result with NO parseable data array: the count is unknown, so it must fall
  // to the softer wording rather than asserting "this is not no-results" about a payload
  // it could not read.
  const unknownShape = degradedSearchNotice({ meta: { fallback: true, fallback_reason: "x" } });
  assert.match(unknownShape, /PARTIAL SEARCH/);
});

test("WIRING: the notice is actually prepended to tool results", () => {
  // A notice nothing calls is the failure mode this whole investigation began with.
  const src = readFileSync(join(here, "..", "index.js"), "utf8");
  assert.match(src, /import \{ degradedSearchNotice \} from "\.\/lib\/search-notices\.js";/);
  assert.match(src, /llmRemediationNotice\(result\) \|\| degradedSearchNotice\(result\)/);
});
