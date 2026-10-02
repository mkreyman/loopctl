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
import { ARTICLE_PATH_ID_TOOLS } from "../lib/article-id.js";
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

test("the id alias covers the three reads, and only them", () => {
  for (const tool of ["knowledge_progressive_drill", "knowledge_article_stats"]) {
    const { args, refusal } = prepareToolCall(tool, { id: UUID }, SCHEMAS);
    assert.equal(refusal, undefined, `${tool} must rescue {id}`);
    assert.equal(args.article_id, UUID);
  }
});

test("terminal verbs never act on a copied id", () => {
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

test("no arguments at all reaches a handler as {}, never undefined", () => {
  for (const raw of [undefined, null, "x", [1]]) {
    const { args, refusal } = prepareToolCall("knowledge_heat_index", raw, SCHEMAS);
    assert.equal(refusal, undefined);
    assert.deepEqual(args, {});
  }
});

test("article ids: a full UUID everywhere, a prefix only where the server resolves one", () => {
  const ok = (tool, id) => prepareToolCall(tool, { article_id: id, reason: "r" }, SCHEMAS);
  assert.equal(ok("knowledge_get", UUID).args.article_id, UUID);
  assert.equal(ok("knowledge_get", "f7e1b841").args.article_id, "f7e1b841");
  assert.equal(ok("knowledge_progressive_drill", "f7e1b841-41").args.article_id, "f7e1b841-41");
  assert.equal(ok("knowledge_archive", UUID).args.article_id, UUID);
  const r = ok("knowledge_archive", "f7e1b841").refusal;
  assert.equal(r?.status, 0, "write verbs take a full UUID");
  assert.match(r.body, /full article UUID/);
  for (const bad of ["f7e1b84", "chain-of-custody", "../system", "[object Object]"]) {
    const refused = ok("knowledge_get", bad).refusal;
    assert.equal(refused?.status, 0, `${JSON.stringify(bad)} must be refused locally`);
    assert.doesNotMatch(refused.body, /chain-of-custody|\.\.\/system/, "never echo the value");
  }
});

test("a padded id is trimmed and used, not refused", () => {
  const { args, refusal } = prepareToolCall("knowledge_get", { article_id: ` ${UUID}\n` }, SCHEMAS);
  assert.equal(refusal, undefined);
  assert.equal(args.article_id, UUID);
});

test("a supplied non-string id is told its type, never that it is missing", () => {
  const { refusal } = prepareToolCall("knowledge_archive", { article_id: 42 }, SCHEMAS);
  assert.equal(refusal.status, 0);
  assert.match(refusal.body, /must be a string id; got a number/);
  assert.doesNotMatch(refusal.body, /required/);
});

test("COMPLETENESS: every handler that puts article_id in a URL path is in ARTICLE_PATH_ID_TOOLS", () => {
  // The check runs at dispatch from the table, so a new handler is covered only by an entry.
  const handlerTool = new Map();
  for (const m of SRC.matchAll(/case "([a-z_]+)":\s*\n\s*return await (\w+)\(args\);/g)) {
    handlerTool.set(m[2], m[1]);
  }
  const interpolating = [];
  for (const m of SRC.matchAll(/\nasync function (\w+)\(/g)) {
    const start = m.index + 1;
    const end = SRC.indexOf("\nasync function ", start + 10);
    const body = SRC.slice(start, end === -1 ? undefined : end);
    if (/`[^`]*\/\$\{article_id\}/.test(body)) interpolating.push(m[1]);
  }
  assert.ok(interpolating.length > 0, "the scan must find the article handlers");
  for (const fn of interpolating) {
    const tool = handlerTool.get(fn);
    assert.ok(tool, `${fn} interpolates article_id but no tool dispatches to it`);
    assert.ok(Object.hasOwn(ARTICLE_PATH_ID_TOOLS, tool), `${tool} (${fn}) puts article_id in a path without a dispatch check`);
  }
});
