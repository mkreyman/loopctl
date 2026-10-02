/**
 * A tool call missing a declared-required argument is refused BEFORE any request, a
 * malformed article id is refused the same way, and knowledge_get accepts the `id`
 * spelling agents actually send.
 *
 * Measured 2026-10-01: all 30 knowledge_get 404s in loopctl's production logs for
 * 2026-09-25..30 were `GET /api/v1/articles/undefined` (38 of 38 reads carrying a real id
 * succeeded), and 17 of 96 knowledge_get calls in local transcripts passed `{"id": ...}`.
 * Agents read the 404 as "the article is gone" and worked from the search snippet instead.
 *
 * The dispatch tests drive lib/dispatch-prep.js with the REAL tool schemas parsed out of
 * index.js, so they fail if the guard is removed, not merely if its text moves.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { applyArgAliases } from "../lib/arg-aliases.js";
import { isBlank, missingRequiredArgs } from "../lib/required-args.js";
import { prepareToolCall } from "../lib/dispatch-prep.js";
import { articleIdRefusal } from "../lib/article-id.js";
import { loadTools, stripComments } from "./tool-surface.js";

const here = dirname(fileURLToPath(import.meta.url));
const SRC = stripComments(readFileSync(join(here, "..", "index.js"), "utf8"));
const SCHEMAS = new Map(loadTools().map((t) => [t.name, t.inputSchema]));
const UUID = "f7e1b841-4102-4e72-83bc-81cfe4a65129";

test("knowledge_get: the observed {id} call is rescued into article_id at dispatch", () => {
  const rescued = [];
  const { args, refusal } = prepareToolCall("knowledge_get", { id: UUID }, SCHEMAS, (p) => rescued.push(p));
  assert.equal(refusal, undefined);
  assert.equal(args.article_id, UUID);
  assert.deepEqual(rescued, [{ canonical: "article_id", alias: "id" }]);
});

test("an explicit article_id wins over id", () => {
  const { args } = prepareToolCall("knowledge_get", { article_id: UUID, id: "other" }, SCHEMAS);
  assert.equal(args.article_id, UUID);
});

test("the id alias is knowledge_get ONLY: terminal verbs never act on a copied id", () => {
  for (const tool of ["knowledge_archive", "knowledge_delete", "knowledge_unpublish", "knowledge_update"]) {
    assert.ok(SCHEMAS.get(tool)?.properties?.article_id, `${tool} must declare article_id`);
    const { args, refusal } = prepareToolCall(tool, { id: UUID }, SCHEMAS);
    assert.equal(args, undefined, `${tool} must not run on {id}`);
    assert.deepEqual([...refusal.body.missing], ["article_id"]);
  }
});

test("the alias never fires for a tool that declares id itself, or does not declare article_id", () => {
  assert.equal(applyArgAliases({ id: "m1" }, null, ["id"], "knowledge_get").article_id, undefined);
  assert.equal(applyArgAliases({ id: "m1" }, null, ["id", "article_id"], "knowledge_get").article_id, undefined);
  assert.equal(applyArgAliases({ id: "p1" }, null, ["post_id"], "knowledge_get").article_id, undefined);
  // Unknown schema (generated cr_* tools): no scoped aliasing at all.
  assert.equal(applyArgAliases({ id: "m1" }, null, undefined, "knowledge_get").article_id, undefined);
});

test("ONE blankness rule: a whitespace article_id is rescued from id, not refused", () => {
  const { args, refusal } = prepareToolCall("knowledge_get", { article_id: "  ", id: UUID }, SCHEMAS);
  assert.equal(refusal, undefined);
  assert.equal(args.article_id, UUID);
  assert.equal(isBlank("  "), true);
  assert.equal(isBlank(0), false);
});

test("missingRequiredArgs names exactly the blank required keys", () => {
  const schema = { required: ["article_id", "mode"] };
  assert.deepEqual(missingRequiredArgs({}, schema), ["article_id", "mode"]);
  assert.deepEqual(missingRequiredArgs({ article_id: "  ", mode: "x" }, schema), ["article_id"]);
  assert.deepEqual(missingRequiredArgs({ article_id: "a", mode: 0 }, schema), []);
  assert.deepEqual(missingRequiredArgs(undefined, schema), ["article_id", "mode"]);
  assert.deepEqual(missingRequiredArgs({}, undefined), []);
});

test("a missing required argument is refused in the house shape, with the parameter's guidance", () => {
  const { args, refusal } = prepareToolCall("handoff", { body: "x", articleId: "y" }, SCHEMAS);
  assert.equal(args, undefined);
  assert.equal(refusal.error, true);
  assert.equal(refusal.status, 0, "status 0 = no request was sent");
  assert.equal(refusal.body.code, "missing_required_argument");
  assert.ok(refusal.body.missing.includes("anchor"));
  assert.deepEqual(refusal.body.passed, ["body", "articleId"]);
  assert.match(refusal.body.guidance.anchor, /handoff:<anchor>/);
  assert.match(refusal.body.message, /No request was sent/);
});

test("a generated cr_* tool is not checked locally", () => {
  const { args, refusal } = prepareToolCall("cr_filter_stories", {}, SCHEMAS);
  assert.equal(refusal, undefined);
  assert.deepEqual(args, {});
});

test("article ids: strict UUID by default, a unique prefix only where the server resolves one", () => {
  assert.equal(articleIdRefusal(UUID), null);
  assert.equal(articleIdRefusal("f7e1b841")?.status, 0, "archive-class verbs take a full UUID");
  assert.equal(articleIdRefusal(UUID, { prefix: true }), null);
  assert.equal(articleIdRefusal("f7e1b841", { prefix: true }), null);
  assert.equal(articleIdRefusal("f7e1b841-41", { prefix: true }), null);
  for (const bad of ["f7e1b84", "chain-of-custody", "../system", "[object Object]", 42]) {
    const r = articleIdRefusal(bad, { prefix: true });
    assert.equal(r?.status, 0, `${JSON.stringify(bad)} must be refused locally`);
    assert.doesNotMatch(String(r.body), /chain-of-custody|\.\.\/system/, "never echo the value");
  }
});

test("WIRING: every handler that puts article_id in a path checks it first", () => {
  const prefix = ["knowledgeGet", "knowledgeProgressiveDrill", "knowledgeArticleStats"];
  const strict = [
    "knowledgeSuggestLinks", "knowledgeUpdate", "knowledgePublish", "knowledgeUnpublish",
    "knowledgeArchive", "knowledgeSuppress", "knowledgeUnsuppress", "knowledgeDelete",
  ];
  for (const fn of [...prefix, ...strict]) {
    const start = SRC.indexOf(`async function ${fn}(`);
    assert.notEqual(start, -1, fn);
    const body = SRC.slice(start, SRC.indexOf("\nasync function ", start + 10));
    const opt = prefix.includes(fn) ? ", \\{ prefix: true \\}" : "";
    assert.match(
      body,
      new RegExp(`^  const badArticleId = articleIdRefusal\\(article_id${opt}\\);\\n  if \\(badArticleId\\) return toContent\\(badArticleId\\);`, "m"),
      `${fn} must refuse a malformed article_id before its request`,
    );
  }
});
