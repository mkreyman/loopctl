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

import { degradedSearchNotice, outcomeOf, OUTCOMES } from "../lib/search-notices.js";

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

// ---------------------------------------------------------------------------
// The uniform tool-outcome envelope. `meta.outcome` is one of
// success | empty | degraded | fallback | error, so the notice no longer infers the
// class from per-surface flag names — and the three classes that need a remedy get
// three DIFFERENT remedies.
// ---------------------------------------------------------------------------

test("outcome: empty gets no notice — silence is what makes it distinct from degraded", () => {
  // The distinction still reaches the agent: the rendered JSON carries
  // meta.outcome: "empty", while a degraded one arrives under a shouting banner.
  assert.equal(degradedSearchNotice({ data: [], meta: { outcome: "empty" } }), null);
  assert.equal(degradedSearchNotice({ data: [{ id: 1 }], meta: { outcome: "success" } }), null);
});

test("outcome: degraded is worded to WAIT, not to retry immediately", () => {
  // A shed serves no substitute lane, so an immediate retry goes back into the same
  // closed gate. Wording it as a fallback would prescribe exactly that.
  const notice = degradedSearchNotice({
    data: [],
    meta: { outcome: "degraded", reason: "heavy_read_overloaded" },
  });

  assert.match(notice, /^outcome: degraded/);
  assert.match(notice, /NOT "NO RESULTS"/);
  assert.match(notice, /heavy_read_overloaded/);
  assert.match(notice, /WAIT/);
});

test("outcome: degraded WITH rows says the set may be short", () => {
  const notice = degradedSearchNotice({
    data: [{ id: 1 }],
    meta: { outcome: "degraded", semantic_under_filled: true },
  });

  assert.match(notice, /^outcome: degraded/);
  assert.match(notice, /PARTIAL RESULTS/);
  assert.match(notice, /semantic_under_filled/, "an unnamed cause is much weaker advice");
});

test("outcome: fallback keeps the do-NOT-rephrase remedy and names its class", () => {
  const notice = degradedSearchNotice({
    data: [],
    meta: { outcome: "fallback", fallback_reason: "embedding_timeout" },
  });

  assert.match(notice, /^outcome: fallback/);
  assert.match(notice, /do NOT rephrase/i);
  assert.match(notice, /RETRY THE SAME QUERY/);
});

test("outcome: error says the retrieval never ran, so the empty proves nothing", () => {
  const notice = degradedSearchNotice({
    data: [],
    meta: { outcome: "error", degraded_reason: "invalid_weights" },
  });

  assert.match(notice, /^outcome: error/);
  assert.match(notice, /DID NOT RUN/);
  assert.match(notice, /invalid_weights/);
  assert.doesNotMatch(notice, /RETRY THE SAME QUERY/, "rerunning a bad request repeats it");
});

test("the BYO-key case still defers, even when the envelope classifies it", () => {
  assert.equal(
    degradedSearchNotice({
      data: [],
      meta: { outcome: "fallback", fallback_reason: "no_embedding_key" },
    }),
    null,
  );
});

test("an unrecognised outcome falls back to the flag heuristics, never to an invented class", () => {
  // A value this client does not know means a server newer than it. Making up a notice
  // for a class we cannot interpret is worse than the pre-envelope behaviour.
  assert.equal(outcomeOf({ meta: { outcome: "provider_error" } }), null);

  const notice = degradedSearchNotice({
    data: [],
    meta: { outcome: "provider_error", fallback: true, fallback_reason: "embedding_timeout" },
  });

  assert.match(notice, /^DEGRADED SEARCH/, "the historical, unprefixed wording");
});

test("a pre-envelope server still gets the #658 notice, with no outcome: claim on it", () => {
  const notice = degradedSearchNotice({
    data: [],
    meta: { fallback: true, fallback_reason: "embedding_timeout" },
  });

  assert.doesNotMatch(notice, /^outcome:/);
});

test("the client vocabulary is exactly what the SERVER publishes", () => {
  // Asserting the list against a hardcoded copy of itself could only go red when someone
  // edited OUTCOMES — the one change they would also update the test for. Read the
  // server's own declaration instead, so a sixth value added there fails HERE, where
  // outcomeOf() would otherwise silently return null and drop the notice.
  const src = readFileSync(join(here, "..", "..", "lib", "loopctl_web", "outcome.ex"), "utf8");
  const declared = src.match(/@outcomes ~w\(([^)]+)\)/);

  assert.ok(declared, "LoopctlWeb.Outcome must declare @outcomes ~w(...)");
  assert.deepEqual(OUTCOMES, declared[1].trim().split(/\s+/));
});

test("a standing condition is not told to wait for what a wait cannot clear", () => {
  // Both of these stand until an operator acts: ann_iterative_scan "unavailable" until
  // the extension is upgraded, embedding_dimension_mismatch until the dimension is
  // reconciled. Prescribing "wait a few seconds, then retry" loops the agent forever on
  // a heavy read. The mismatch reaches the client as "degraded" rather than "error"
  // precisely when the OTHER half returned rows, which is when the loop is cheapest to
  // start and hardest to notice.
  const standing = [
    { ann_iterative_scan: "unavailable", cause: "ann_iterative_scan_unavailable" },
    { degraded_reason: "embedding_dimension_mismatch", cause: "embedding_dimension_mismatch" },
  ];

  for (const { cause, ...meta } of standing) {
    for (const count of [0, 5]) {
      const notice = degradedSearchNotice({
        data: Array.from({ length: count }, (_, i) => ({ id: i })),
        meta: { outcome: "degraded", ...meta },
      });

      assert.match(notice, /^outcome: degraded/);
      assert.match(notice, new RegExp(cause), "the cause must be named");
      assert.match(notice, /does NOT clear this/);
      assert.doesNotMatch(notice, /[Ww]ait a few seconds/);
    }
  }
});

test("every retrieval tool that carries meta.outcome also PRINTS the banner", () => {
  // The finding this closes: the server classified nine retrieval responses and the
  // client acted on three of them. On the six below the handler ended at a bare
  // `toContent(result)`, so `outcome: "degraded"` rode into the JSON and nothing read
  // it — a shed memory recall still looked exactly like an empty scope, which is the
  // one misread the whole envelope exists to end.
  //
  // Anchored to index.js's SOURCE rather than to a re-implementation of the handlers,
  // because the handlers are not exported: a copy in this file would assert only about
  // the copy. Each handler's body is sliced out and required to end in the wrapper.
  const src = readFileSync(join(here, "..", "index.js"), "utf8");

  const handlers = [
    "knowledgeSearch",
    "knowledgeHybridSearch",
    "knowledgeContext",
    "knowledgeProgressiveIndex",
    "knowledgeHeatIndex",
    "knowledgeList",
    "memoryRecall",
    "recallContext",
    "corpusSearch",
  ];

  for (const name of handlers) {
    const start = src.indexOf(`async function ${name}(`);
    assert.notEqual(start, -1, `${name} must exist in index.js`);
    const end = src.indexOf("\n}\n", start);
    assert.notEqual(end, -1, `${name} must have a closing brace`);
    const body = src.slice(start, end);

    assert.match(
      body,
      /return withRemediationNotice\(result\);/,
      `${name} must return through withRemediationNotice — a bare toContent drops the ` +
        `outcome banner and the degradation is silent at the client`,
    );
    assert.doesNotMatch(
      body,
      /return toContent\(result\);/,
      `${name} must not also have a bare toContent return path`,
    );
  }
});
