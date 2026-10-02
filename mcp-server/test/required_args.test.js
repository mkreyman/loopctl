/**
 * A tool call missing a declared-required argument is refused BEFORE any request, and
 * knowledge_get accepts the `id` spelling agents actually send.
 *
 * Measured 2026-10-01: all 30 knowledge_get 404s in loopctl's production logs for
 * 2026-09-25..30 were `GET /api/v1/articles/undefined` (38 of 38 reads carrying a real id
 * succeeded), and 17 of 96 knowledge_get calls in local transcripts passed `{"id": ...}`.
 * Agents read the 404 as "the article is gone" and worked from the search snippet instead.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { applyArgAliases } from "../lib/arg-aliases.js";
import { missingRequiredArgs, requiredArgsRefusal } from "../lib/required-args.js";

const here = dirname(fileURLToPath(import.meta.url));
const SRC = readFileSync(join(here, "..", "index.js"), "utf8");

const KNOWLEDGE_GET_ARGS = ["article_id", "project_id", "story_id", "links", "body_max_bytes", "body_offset"];
const MEMORY_FORGET_ARGS = ["id"];

test("knowledge_get: the observed {id} call is rescued into article_id", () => {
  const rescued = [];
  const out = applyArgAliases(
    { id: "f7e1b841-4102-4e72-83bc-81cfe4a65129" },
    (pair) => rescued.push(pair),
    KNOWLEDGE_GET_ARGS,
  );
  assert.equal(out.article_id, "f7e1b841-4102-4e72-83bc-81cfe4a65129");
  assert.deepEqual(rescued, [{ canonical: "article_id", alias: "id" }]);
});

test("an explicit article_id wins over id", () => {
  const out = applyArgAliases({ article_id: "real", id: "other" }, null, KNOWLEDGE_GET_ARGS);
  assert.equal(out.article_id, "real");
});

test("the id alias never fires for a tool that declares id itself, or does not declare article_id", () => {
  assert.equal(applyArgAliases({ id: "m1" }, null, MEMORY_FORGET_ARGS).article_id, undefined);
  assert.equal(applyArgAliases({ id: "m1" }, null, ["id", "article_id"]).article_id, undefined);
  // A tool that declares neither must not grow an article_id it never reads.
  assert.equal(applyArgAliases({ id: "p1" }, null, ["post_id"]).article_id, undefined);
  // Unknown schema (generated cr_* tools): no scoped aliasing at all.
  assert.equal(applyArgAliases({ id: "m1" }).article_id, undefined);
});

test("missingRequiredArgs names exactly the blank required keys", () => {
  const schema = { required: ["article_id", "mode"] };
  assert.deepEqual(missingRequiredArgs({}, schema), ["article_id", "mode"]);
  assert.deepEqual(missingRequiredArgs({ article_id: "  ", mode: "x" }, schema), ["article_id"]);
  assert.deepEqual(missingRequiredArgs({ article_id: "a", mode: 0 }, schema), []);
  assert.deepEqual(missingRequiredArgs(undefined, schema), ["article_id", "mode"]);
  assert.deepEqual(missingRequiredArgs({}, undefined), []);
});

test("the refusal is an isError result naming the missing and the received keys", () => {
  const res = requiredArgsRefusal("knowledge_get", ["article_id"], { articleId: "x" });
  assert.equal(res.isError, true);
  const body = JSON.parse(res.content[0].text);
  assert.equal(body.code, "missing_required_argument");
  assert.deepEqual(body.missing, ["article_id"]);
  assert.deepEqual(body.passed, ["articleId"]);
  assert.match(body.message, /No request was sent/);
});

test("WIRING: dispatch refuses missing required args after aliasing and before the switch", () => {
  const dispatch = SRC.slice(SRC.indexOf("server.setRequestHandler(CallToolRequestSchema"));
  const alias = dispatch.indexOf("applyArgAliases(");
  const check = dispatch.indexOf("missingRequiredArgs(args, TOOL_SCHEMAS.get(name))");
  const refuse = dispatch.indexOf("return requiredArgsRefusal(name, missing, args)");
  const sw = dispatch.indexOf("switch (name)");
  assert.ok(alias !== -1 && check !== -1 && refuse !== -1 && sw !== -1);
  assert.ok(alias < check && check < refuse && refuse < sw, "alias, then check, then dispatch");
  assert.match(SRC, /const TOOL_SCHEMAS = new Map\(TOOLS\.map\(\(t\) => \[t\.name, t\.inputSchema\]\)\);/);
});

test("knowledge_get still declares article_id required, so the guard covers it", () => {
  const start = SRC.indexOf('name: "knowledge_get"');
  const seg = SRC.slice(start, SRC.indexOf("\n    name: ", start + 10));
  assert.match(seg, /required: \["article_id"\]/);
});
