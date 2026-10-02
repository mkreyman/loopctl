/**
 * knowledge_get (and its two sibling reads) accept the `id` spelling agents send, and a
 * request with an unfilled path argument is refused before it is sent.
 *
 * Measured 2026-10-01: all 30 knowledge_get 404s in loopctl's production logs for
 * 2026-09-25..30 were `GET /api/v1/articles/undefined` (38 of 38 reads carrying a real id
 * succeeded), and 17 of 96 knowledge_get calls in mac-mini's transcripts passed
 * `{"id": ...}`. Agents read the 404 as "the article is gone".
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { applyArgAliases, TOOL_SCOPED_ALIASES } from "../lib/arg-aliases.js";
import { unfilledPathRefusal } from "../lib/path-guard.js";
import { loadTools, stripComments } from "./tool-surface.js";

const here = dirname(fileURLToPath(import.meta.url));
const SRC = stripComments(readFileSync(join(here, "..", "index.js"), "utf8"));
const DECLARED = new Map(loadTools().map((t) => [t.name, Object.keys(t.inputSchema.properties)]));
const UUID = "f7e1b841-4102-4e72-83bc-81cfe4a65129";

const call = (tool, args, seen) =>
  applyArgAliases(args, seen ? (p) => seen.push(p) : undefined, DECLARED.get(tool), tool);

test("the article reads rescue {id} into article_id, and report the rescue", () => {
  const reads = [
    "knowledge_get",
    "knowledge_progressive_drill",
    "knowledge_article_stats",
    "knowledge_suggest_links",
    "knowledge_graph",
  ];
  for (const tool of reads) {
    const seen = [];
    assert.equal(call(tool, { id: UUID }, seen).article_id, UUID, tool);
    assert.deepEqual(seen, [{ canonical: "article_id", alias: "id" }], tool);
  }
});

test("an explicit article_id wins over id", () => {
  assert.equal(call("knowledge_get", { article_id: UUID, id: "other" }).article_id, UUID);
});

test("write verbs never take id: a copied id cannot archive or delete anything", () => {
  for (const tool of ["knowledge_archive", "knowledge_delete", "knowledge_unpublish", "knowledge_update"]) {
    assert.ok(DECLARED.get(tool).includes("article_id"), tool);
    assert.equal(call(tool, { id: UUID }).article_id, undefined, tool);
  }
});

test("the alias needs the tool's schema, and never renames a tool's own id", () => {
  assert.equal(applyArgAliases({ id: UUID }, null, undefined, "knowledge_get").article_id, undefined);
  assert.equal(applyArgAliases({ id: UUID }, null, ["id", "article_id"], "knowledge_get").article_id, undefined);
  assert.equal(applyArgAliases({ id: UUID }, null, ["post_id"], "knowledge_get").article_id, undefined);
});

test("every TOOL_SCOPED_ALIASES key is a real tool declaring the canonical", () => {
  for (const [tool, map] of Object.entries(TOOL_SCOPED_ALIASES)) {
    assert.ok(DECLARED.has(tool), `${tool} is not a declared tool`);
    for (const canonical of Object.keys(map)) {
      assert.ok(DECLARED.get(tool).includes(canonical), `${tool} must declare ${canonical}`);
    }
  }
});

test("unfilled, blank and dot segments are refused locally; filled ones and the query are not", () => {
  for (const p of [
    "/api/v1/articles/undefined",
    "/api/v1/articles/undefined?links=none",
    "/api/v1/articles/",
    "/api/v1/articles/?links=none",
    "/api/v1/knowledge/articles//stats",
    "/api/v1/knowledge/articles/../../stories/stats",
    "/api/v1/articles/./x",
  ]) {
    const r = unfilledPathRefusal(p);
    assert.equal(r?.error, true, p);
    assert.equal(r.status, 0, p);
    assert.match(r.body, /never requested/);
    assert.match(r.body, /<missing>/);
    assert.doesNotMatch(r.body, /article_id/, "the guard knows no tool, so it names no parameter");
  }
  assert.equal(unfilledPathRefusal(`/api/v1/articles/${UUID}`), null);
  assert.equal(unfilledPathRefusal("/api/v1/knowledge/search?q=undefined"), null);
  assert.equal(unfilledPathRefusal("/api/v1/articles/undefined-behaviour"), null);
  assert.equal(unfilledPathRefusal("/api/v1/egress/trusted-endpoints/null"), null, "null is a value");
});

test("WIRING, end to end: the real server rescues {id} and never sends an unfilled path", async () => {
  const seen = [];
  const http = await import("node:http");
  const { spawn } = await import("node:child_process");
  const server = http.createServer((req, res) => {
    seen.push(req.url);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ data: { id: UUID } }));
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const { port } = server.address();

  const child = spawn(process.execPath, [join(here, "..", "index.js")], {
    env: {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      LOOPCTL_SERVER: `http://127.0.0.1:${port}`,
      LOOPCTL_AGENT_KEY: "lc_test_agent",
      LOOPCTL_ORCH_KEY: "lc_test_orch",
    },
    stdio: ["pipe", "pipe", "ignore"],
  });
  let buf = "";
  const replies = new Map();
  child.stdout.on("data", (d) => {
    buf += d;
    let nl;
    while ((nl = buf.indexOf("\n")) !== -1) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      try {
        const msg = JSON.parse(line);
        if (msg.id !== undefined) replies.set(msg.id, msg);
      } catch {}
    }
  });
  const send = (msg) => child.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...msg }) + "\n");
  const reply = async (id) => {
    for (let i = 0; i < 200 && !replies.has(id); i++) await new Promise((r) => setTimeout(r, 25));
    assert.ok(replies.has(id), `no reply to request ${id}`);
    return replies.get(id);
  };

  try {
    send({ id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "t", version: "0" } } });
    await reply(1);
    send({ method: "notifications/initialized" });

    send({ id: 2, method: "tools/call", params: { name: "knowledge_get", arguments: { id: UUID } } });
    const ok = await reply(2);
    assert.notEqual(ok.result?.isError, true, JSON.stringify(ok));
    assert.ok(seen.some((u) => u.startsWith(`/api/v1/articles/${UUID}`)), `requested ${seen}`);

    for (const [rid, args] of [[3, {}], [4, { article_id: "" }], [5, { article_id: "../../stories" }]]) {
      const before = seen.length;
      send({ id: rid, method: "tools/call", params: { name: "knowledge_article_stats", arguments: args } });
      const refused = await reply(rid);
      assert.equal(refused.result?.isError, true, JSON.stringify(args));
      assert.match(refused.result.content[0].text, /never requested/);
      assert.equal(seen.length, before, `nothing may be sent for ${JSON.stringify(args)}`);
    }
  } finally {
    child.kill();
    server.close();
  }
});
