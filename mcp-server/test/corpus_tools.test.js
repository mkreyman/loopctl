/**
 * US-43.4 — the `corpus_*` MCP tool surface.
 *
 * SINGLE SOURCE OF TRUTH. Every path builder and every request-body builder the
 * six corpus tools use lives in ../lib/http-helpers.js and is IMPORTED here, so
 * these tests exercise the code the server actually ships (AC-43.4.6).
 *
 * This is deliberately NOT the shape of test/knowledge_tools.test.js, whose own
 * header records that it re-implements the handler bodies inside the test file —
 * those tests pass against a mirror while index.js regresses underneath them.
 *
 * The wiring assertions additionally SOURCE-PIN index.js through `functionSource`
 * (the test/mcp_arg_forwarding.test.js discipline): a bare /async function foo\(
 * [\s\S]*?needle/ scan spans forward without limit and can be satisfied by a LATER
 * function's body, which is a vacuous pass. Slicing the named function out first
 * makes every assertion provably about that function.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  corporaPath,
  corpusPath,
  corpusIndexPath,
  corpusSearchPath,
  corpusStatusPath,
  buildCorpusCreateBody,
  buildCorpusIndexBody,
  buildCorpusSearchBody,
} from "../lib/http-helpers.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");
const REPO_CLAUDE_MD = readFileSync(path.join(DIR, "..", "..", "CLAUDE.md"), "utf8");
const REPO_AGENTS_MD = readFileSync(path.join(DIR, "..", "..", "AGENTS.md"), "utf8");
const KB_SKILL = readFileSync(
  path.join(DIR, "..", "..", ".claude", "skills", "knowledge-wiki", "SKILL.md"),
  "utf8",
);

/** Tool name -> the handler its dispatch case MUST call. */
const CORPUS_DISPATCH = {
  corpus_create: "corpusCreate",
  corpus_index: "corpusIndex",
  corpus_search: "corpusSearch",
  corpus_list: "corpusList",
  corpus_status: "corpusStatus",
  corpus_delete: "corpusDelete",
};

const CORPUS_TOOLS = Object.keys(CORPUS_DISPATCH);

function functionSource(name) {
  const declaration = `async function ${name}(`;
  const start = INDEX_SRC.indexOf(declaration);
  assert.notEqual(start, -1, `index.js must define ${declaration}`);
  const rest = INDEX_SRC.slice(start + declaration.length);
  // Bound at whichever comes first: the next top-level `async function`, or this
  // function's own column-0 closing brace. The second bound matters for the LAST
  // handler in a run — without it the slice reaches EOF and picks up the dispatch
  // switch, which mentions every key name and makes a negative assertion vacuous.
  const bounds = ["\nasync function ", "\n}\n"]
    .map((marker) => rest.indexOf(marker))
    .filter((at) => at !== -1);
  const body = bounds.length === 0 ? rest : rest.slice(0, Math.min(...bounds));
  assert.ok(body.trim().length > 0, `${name} must have a body`);
  return body;
}

/** The `{ name: "x", description: ..., inputSchema: ... }` slice for one static tool. */
function toolDefinitionSource(name) {
  const start = INDEX_SRC.indexOf(`name: "${name}",`);
  assert.notEqual(start, -1, `index.js must declare a tool named ${name}`);
  const rest = INDEX_SRC.slice(start);
  // Bound at whichever comes first: the next tool object, or the TOOLS array's own
  // terminator. The second bound matters for the LAST entry (corpus_delete) — without
  // it the slice runs past `];` to EOF, and the description assertions are satisfied
  // by any unrelated source that happens to follow.
  const bounds = ["\n  {\n", "\n];\n"]
    .map((marker) => rest.indexOf(marker))
    .filter((at) => at !== -1);
  return bounds.length === 0 ? rest : rest.slice(0, Math.min(...bounds));
}

// ---------------------------------------------------------------------------
// Path building (AC-43.4.6)
// ---------------------------------------------------------------------------

describe("corpus path builders", () => {
  test("corporaPath with no args is the bare collection route", () => {
    assert.equal(corporaPath(), "/api/v1/corpora");
    assert.equal(corporaPath({}), "/api/v1/corpora");
  });

  test("corporaPath forwards project_id/limit/offset and omits unset ones", () => {
    assert.equal(
      corporaPath({ project_id: "p-1", limit: 10, offset: 20 }),
      "/api/v1/corpora?project_id=p-1&limit=10&offset=20",
    );
    assert.equal(corporaPath({ limit: 5, offset: undefined }), "/api/v1/corpora?limit=5");
    assert.equal(corporaPath({ project_id: null }), "/api/v1/corpora");
  });

  test("corpusPath/index/search/status address one corpus", () => {
    assert.equal(corpusPath("specs"), "/api/v1/corpora/specs");
    assert.equal(corpusIndexPath("specs"), "/api/v1/corpora/specs/index");
    assert.equal(corpusSearchPath("specs"), "/api/v1/corpora/specs/search");
    assert.equal(corpusStatusPath("specs"), "/api/v1/corpora/specs/status");
  });

  test("the id segment is encoded — it accepts a client-supplied slug, not just a UUID", () => {
    assert.equal(corpusPath("a b/c"), "/api/v1/corpora/a%20b%2Fc");
    assert.equal(corpusSearchPath("a/b"), "/api/v1/corpora/a%2Fb/search");
  });

  test("corpusStatusPath paginates", () => {
    assert.equal(
      corpusStatusPath("specs", { limit: 50, offset: 100 }),
      "/api/v1/corpora/specs/status?limit=50&offset=100",
    );
    assert.equal(corpusStatusPath("specs", {}), "/api/v1/corpora/specs/status");
    assert.equal(corpusStatusPath("specs", { limit: 50 }), "/api/v1/corpora/specs/status?limit=50");
  });
});

// ---------------------------------------------------------------------------
// Body building (AC-43.4.6)
// ---------------------------------------------------------------------------

describe("buildCorpusCreateBody", () => {
  test("forwards every declared attribute", () => {
    assert.deepEqual(
      buildCorpusCreateBody({
        slug: "specs",
        name: "Specs",
        mode: "server_embedded",
        embedding_model: "text-embedding-3-small",
        dim: 1536,
        description: "the specs",
        project_id: "p-1",
        allow_snippets: true,
      }),
      {
        slug: "specs",
        name: "Specs",
        mode: "server_embedded",
        embedding_model: "text-embedding-3-small",
        dim: 1536,
        description: "the specs",
        project_id: "p-1",
        allow_snippets: true,
      },
    );
  });

  test("omits unset optionals rather than sending null", () => {
    const body = buildCorpusCreateBody({
      slug: "s",
      name: "n",
      mode: "client_embedded",
      embedding_model: "local",
      dim: 768,
      description: undefined,
      project_id: null,
    });
    assert.deepEqual(body, {
      slug: "s",
      name: "n",
      mode: "client_embedded",
      embedding_model: "local",
      dim: 768,
    });
  });

  test("allow_snippets: false survives — it is the mode B default, not an unset flag", () => {
    // A truthiness filter here would silently drop an explicit privacy opt-out.
    const body = buildCorpusCreateBody({ slug: "s", allow_snippets: false });
    assert.equal(body.allow_snippets, false);
    assert.ok("allow_snippets" in body);
  });

  test("dim: 0 is forwarded, not treated as absent (the server names the error)", () => {
    assert.equal(buildCorpusCreateBody({ dim: 0 }).dim, 0);
  });

  test("drops unknown keys instead of forwarding them", () => {
    assert.deepEqual(buildCorpusCreateBody({ slug: "s", tenant_id: "nope" }), { slug: "s" });
  });
});

describe("buildCorpusIndexBody", () => {
  const chunk = { source_ref: "docs/spec.md", locator: { line: 12 }, text: "hello" };

  test("forwards chunks verbatim — the shape is mode-dependent and the server decides", () => {
    assert.deepEqual(buildCorpusIndexBody({ chunks: [chunk] }), { chunks: [chunk] });
  });

  test("forwards source_complete in its BARE-STRING form (AC-43.2.3 prune)", () => {
    const body = buildCorpusIndexBody({ chunks: [chunk], source_complete: ["docs/spec.md"] });
    assert.deepEqual(body.source_complete, ["docs/spec.md"]);
  });

  test("forwards source_complete in its MANIFEST form, for a multi-batch document", () => {
    const manifest = [{ source_ref: "docs/spec.md", locators: [{ line: 12 }, { line: 40 }] }];
    const body = buildCorpusIndexBody({ chunks: [chunk], source_complete: manifest });
    assert.deepEqual(body.source_complete, manifest);
  });

  test("omits source_complete when unset — an omitted list must never read as an EMPTY one", () => {
    // `source_complete: []` reconciles nothing; sending it for an unset arg would be
    // indistinguishable server-side, so absence has to stay absence.
    const body = buildCorpusIndexBody({ chunks: [chunk] });
    assert.ok(!("source_complete" in body));
  });

  test("a mode B chunk carrying a vector + content_hash passes through unreshaped", () => {
    const modeB = {
      source_ref: "docs/spec.md",
      locator: { page: 47 },
      vector: [0.1, 0.2, 0.3],
      content_hash: "sha256:abc",
    };
    assert.deepEqual(buildCorpusIndexBody({ chunks: [modeB] }).chunks, [modeB]);
  });

  test("defaults chunks to an empty array rather than emitting an absent key", () => {
    assert.deepEqual(buildCorpusIndexBody({}), { chunks: [] });
    assert.deepEqual(buildCorpusIndexBody(), { chunks: [] });
  });
});

describe("buildCorpusSearchBody", () => {
  test("mode A: forwards `query` and emits NO query_vector key", () => {
    const body = buildCorpusSearchBody({ query: "retention period" });
    assert.deepEqual(body, { query: "retention period" });
    assert.ok(!("query_vector" in body));
  });

  test("mode B: forwards a VECTOR rather than a query string (AC-43.4.6)", () => {
    const vector = [0.5, -0.25, 0.125];
    const body = buildCorpusSearchBody({ query_vector: vector, limit: 5 });
    assert.deepEqual(body.query_vector, vector);
    assert.ok(
      !("query" in body),
      "a mode B search must not carry a query string — the server refuses one (422 query_string_not_accepted)",
    );
    assert.equal(body.limit, 5);
  });

  test("an unset query_vector is OMITTED, never sent as null", () => {
    // The search action dispatches on the VALUE: an explicit null sent a mode A
    // request down the mode B path, to be refused with query_vector_not_accepted.
    const body = buildCorpusSearchBody({ query: "x", query_vector: null });
    assert.ok(!("query_vector" in body));
  });

  test("an EMPTY query_vector is forwarded — the server refuses it by name", () => {
    const body = buildCorpusSearchBody({ query_vector: [] });
    assert.deepEqual(body.query_vector, []);
  });

  test("both query and query_vector are forwarded, so the server can answer ambiguous_query", () => {
    const body = buildCorpusSearchBody({ query: "x", query_vector: [1, 2] });
    assert.equal(body.query, "x");
    assert.deepEqual(body.query_vector, [1, 2]);
  });

  test("forwards lanes and omits unset optionals", () => {
    assert.deepEqual(buildCorpusSearchBody({ query: "x", lanes: ["semantic"] }), {
      query: "x",
      lanes: ["semantic"],
    });
    assert.deepEqual(buildCorpusSearchBody({ query: "x" }), { query: "x" });
    assert.deepEqual(buildCorpusSearchBody({}), {});
  });
});

// ---------------------------------------------------------------------------
// index.js wiring — declaration, dispatch, key selection, helper use
// ---------------------------------------------------------------------------

describe("index.js wiring (AC-43.4.1)", () => {
  for (const [name, handler] of Object.entries(CORPUS_DISPATCH)) {
    test(`${name} is declared and dispatched to ${handler}`, () => {
      assert.ok(INDEX_SRC.includes(`name: "${name}",`), `${name} must be in TOOLS`);
      // Pin the case to its HANDLER, not just to the label — the discipline in
      // test/mcp_arg_forwarding.test.js and test/memory_tools.test.js. A label-only
      // `includes` is satisfied whichever function the case returns, so
      // `case "corpus_status": return await corpusList(args);` would pass it while
      // the tool answers with the corpus LIST. Nothing else executes this switch:
      // the builder tests import lib/http-helpers.js, and the Elixir journey test
      // runs no JavaScript.
      assert.match(
        INDEX_SRC,
        new RegExp(`case "${name}":\\s*\\n\\s*return await ${handler}\\(args\\);`),
        `${name} must dispatch to ${handler}(args)`,
      );
    });
  }

  test("every corpus handler builds its path with the shared helper, not inline", () => {
    assert.match(functionSource("corpusCreate"), /corporaPath\(/);
    assert.match(functionSource("corpusList"), /corporaPath\(args\)/);
    assert.match(functionSource("corpusIndex"), /corpusIndexPath\(corpus_id\)/);
    assert.match(functionSource("corpusSearch"), /corpusSearchPath\(corpus_id\)/);
    assert.match(functionSource("corpusStatus"), /corpusStatusPath\(corpus_id, \{ limit, offset \}\)/);
    assert.match(functionSource("corpusDelete"), /corpusPath\(corpus_id\)/);
  });

  test("every corpus handler builds its body with the shared helper, not inline", () => {
    assert.match(functionSource("corpusCreate"), /buildCorpusCreateBody\(/);
    assert.match(functionSource("corpusIndex"), /buildCorpusIndexBody\(/);
    assert.match(functionSource("corpusSearch"), /buildCorpusSearchBody\(/);
  });

  test("corpusIndex forwards source_complete — without it the prune is unreachable", () => {
    const src = functionSource("corpusIndex");
    assert.match(src, /source_complete/);
    assert.match(src, /buildCorpusIndexBody\(\{ chunks, source_complete \}\)/);
  });

  test("corpusSearch forwards query, query_vector, lanes and limit", () => {
    const src = functionSource("corpusSearch");
    assert.match(src, /buildCorpusSearchBody\(\{ query, query_vector, lanes, limit \}\)/);
  });

  test("agent-role corpus tools send LOOPCTL_AGENT_KEY", () => {
    for (const fn of [
      "corpusCreate",
      "corpusList",
      "corpusIndex",
      "corpusSearch",
      "corpusStatus",
    ]) {
      assert.match(
        functionSource(fn),
        /process\.env\.LOOPCTL_AGENT_KEY/,
        `${fn} must authenticate with the agent key`,
      );
    }
  });

  test("corpusDelete sends LOOPCTL_USER_KEY — DELETE is the one user-role verb here", () => {
    const src = functionSource("corpusDelete");
    assert.match(src, /process\.env\.LOOPCTL_USER_KEY/);
    assert.ok(
      !src.includes("LOOPCTL_AGENT_KEY"),
      "corpus_delete must not fall back to the agent key",
    );
    assert.match(src, /"DELETE"/);
  });

  test("the HTTP verbs match the routes", () => {
    assert.match(functionSource("corpusCreate"), /"POST"/);
    assert.match(functionSource("corpusIndex"), /"POST"/);
    assert.match(functionSource("corpusSearch"), /"POST"/);
    assert.match(functionSource("corpusList"), /"GET"/);
    assert.match(functionSource("corpusStatus"), /"GET"/);
  });

  test("corpus_search is NOT wired into the recall path", () => {
    // The controller moduledoc forbids it: verbatim spec chunks auto-injected into
    // every session are exactly the pollution the separate tables prevent.
    // Via functionSource, NOT an inline slice: on a renamed target indexOf returns
    // -1 and the slice collapses to the empty string, which passes a NEGATIVE
    // assertion vacuously. functionSource asserts the declaration exists and the
    // body is non-empty first.
    assert.ok(
      !/corpus/i.test(functionSource("recallContext")),
      "recallContext must not reach the corpus tier",
    );
  });
});

// ---------------------------------------------------------------------------
// Tool descriptions carry the trade-off (AC-43.4.2)
// ---------------------------------------------------------------------------

describe("tool descriptions state the trade-off (AC-43.4.2)", () => {
  test("corpus_search says it returns pointers and snippets, not bodies", () => {
    const src = toolDefinitionSource("corpus_search");
    assert.match(src, /POINTERS/);
    assert.match(src, /snippet/);
    assert.match(src, /open the file/);
  });

  test("corpus_search names the mode restriction, so it is never learned from an error", () => {
    const src = toolDefinitionSource("corpus_search");
    assert.match(src, /client_embedded/);
    assert.match(src, /SEMANTIC-ONLY/);
    assert.match(src, /query_string_not_accepted/);
  });

  test("corpus_search disambiguates itself from knowledge_search in its first sentence", () => {
    const src = toolDefinitionSource("corpus_search");
    const firstSentence = src.slice(0, src.indexOf("TRADE-OFF"));
    assert.match(firstSentence, /knowledge_search/);
    assert.match(firstSentence, /VERBATIM/);
  });

  test("corpus_create explains why mode B is semantic-only: there is no text to index", () => {
    const src = toolDefinitionSource("corpus_create");
    assert.match(src, /semantic-only/i);
    assert.match(src, /allow_snippets defaults to FALSE/);
    assert.match(src, /no_embedding_key/);
  });

  test("corpus_index names text_not_accepted and the source_complete prune", () => {
    const src = toolDefinitionSource("corpus_index");
    assert.match(src, /text_not_accepted/);
    assert.match(src, /source_complete/);
    assert.match(src, /DELETED/);
  });

  test("corpus_delete says it is irreversible and requires the user key", () => {
    const src = toolDefinitionSource("corpus_delete");
    assert.match(src, /IRREVERSIBLE/);
    assert.match(src, /LOOPCTL_USER_KEY/);
  });
});

// ---------------------------------------------------------------------------
// Docs (AC-43.4.3, TC-43.4.5)
// ---------------------------------------------------------------------------

describe("README carries the corpus family (AC-43.4.3)", () => {
  for (const name of CORPUS_TOOLS) {
    test(`README documents ${name}`, () => {
      assert.ok(README.includes(`\`${name}\``), `README must list ${name}`);
    });
  }

  test("neither doc writes an inventory count of tools (TC-43.4.5)", () => {
    // The doc-hygiene rule in CLAUDE.md: counts are wrong by the next merge, and a
    // whole PR (#147) was once spent resyncing one. Write the pointer instead.
    const countLine = /\b\d+\s+(static\s+)?(mcp\s+)?tools\b/i;
    for (const [label, doc] of [
      ["mcp-server/README.md", README],
      ["CLAUDE.md", REPO_CLAUDE_MD],
    ]) {
      const offenders = doc.split("\n").filter((line) => countLine.test(line));
      assert.deepEqual(offenders, [], `${label} must not carry a tool count`);
    }
  });
});

describe("the routing rule reaches the docs an agent reads (AC-43.4.4/AC-43.4.5)", () => {
  test("CLAUDE.md routes the four surfaces and names the failure the rule prevents", () => {
    assert.match(REPO_CLAUDE_MD, /`corpus_\*` \(Corpus tier\)/);
    assert.match(REPO_CLAUDE_MD, /Rule\s+of\s+thumb:\s+\*quote\s+me\s+the\s+exact\s+text[\s\S]{0,200}?corpus_search/);
    // AC-43.4.5: what going wrong LOOKS like, not just what to call.
    // (the docs are hard-wrapped, so every phrase below tolerates a line break)
    assert.match(REPO_CLAUDE_MD, /distillation\s+of\s+a\s+document\s+whose\s+VERBATIM\s+text\s+you\s+needed/);
    assert.match(REPO_CLAUDE_MD, /reading\s+an\s+empty\s+wiki\s+result\s+as\s+an\s+empty\s+corpus/i);
    // The bullet must say what comes back, so the caller knows to open the file.
    assert.match(REPO_CLAUDE_MD, /POINTER\s+plus\s+a\s+bounded\s+snippet/);
  });

  test("AGENTS.md carries the same routing — CLAUDE.md mandates reading it", () => {
    // CLAUDE.md's fourth line says "Also read AGENTS.md", so a stale copy here is a
    // guaranteed misroute, not a cosmetic drift: an agent needing verbatim text finds
    // no clause for it in the Rule of thumb and falls through to knowledge_search.
    assert.match(REPO_AGENTS_MD, /FOUR agent information surfaces/);
    assert.doesNotMatch(REPO_AGENTS_MD, /THREE agent information surfaces/);
    assert.match(REPO_AGENTS_MD, /\*\*`corpus_\*` — Corpus tier\*\*/);
    assert.match(REPO_AGENTS_MD, /quote\s+me\s+the\s+exact\s+text[\s\S]{0,200}?corpus_search/);
  });

  test("the knowledge-wiki skill routes corpus_* — it loads when an agent picks a verb", () => {
    // CLAUDE.md's domain-skill routing table hands this file to anyone touching
    // "Knowledge Wiki, agent memory, context retriever, hybrid search" — i.e. exactly
    // the agent choosing a retrieval verb.
    assert.match(KB_SKILL, /## Four surfaces/);
    assert.doesNotMatch(KB_SKILL, /three (agent information surfaces|distinct agent-facing surfaces)/);
    assert.match(KB_SKILL, /`corpus_\*` \*\*Corpus tier\*\*/);
    assert.match(KB_SKILL, /quote\s+me\s+the\s+exact\s+text[\s\S]{0,200}?corpus_search/);
  });
});
