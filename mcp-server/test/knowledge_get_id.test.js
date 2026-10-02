/**
 * knowledge_get accepts the `id` spelling agents send, and checks the id before sending.
 *
 * Measured 2026-10-01: all 30 knowledge_get 404s in loopctl's production logs for
 * 2026-09-25..30 were `GET /api/v1/articles/undefined` (38 of 38 reads carrying a real id
 * succeeded), and 17 of 96 knowledge_get calls in mac-mini's transcripts passed
 * `{"id": ...}`. Agents read the 404 as "the article is gone".
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import http from "node:http";
import { spawn } from "node:child_process";

import { applyArgAliases, TOOL_SCOPED_ALIASES } from "../lib/arg-aliases.js";
import { uuid, articleId } from "../lib/delivery-loop.js";
import { readFileSync } from "node:fs";
import { stripComments } from "./tool-surface.js";
import { loadTools } from "./tool-surface.js";

const here = dirname(fileURLToPath(import.meta.url));
const DECLARED = new Map(loadTools().map((t) => [t.name, Object.keys(t.inputSchema.properties)]));
const UUID = "f7e1b841-4102-4e72-83bc-81cfe4a65129";

const call = (tool, args, seen) =>
  applyArgAliases(args, seen ? (p) => seen.push(p) : undefined, DECLARED.get(tool), tool);

test("knowledge_get rescues {id} into article_id, and reports the rescue", () => {
  const seen = [];
  assert.equal(call("knowledge_get", { id: UUID }, seen).article_id, UUID);
  assert.deepEqual(seen, [{ canonical: "article_id", alias: "id" }]);
  assert.equal(call("knowledge_get", { article_id: UUID, id: "other" }).article_id, UUID);
});

test("the alias is knowledge_get only: siblings and write verbs are not renamed", () => {
  for (const tool of ["knowledge_progressive_drill", "knowledge_archive", "knowledge_delete", "knowledge_update"]) {
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
    for (const [canonical, aliases] of Object.entries(map)) {
      assert.ok(DECLARED.get(tool).includes(canonical), `${tool} must declare ${canonical}`);
      for (const alias of aliases) {
        assert.ok(!DECLARED.get(tool).includes(alias), `${tool} declares ${alias} itself, so the alias would never fire`);
      }
    }
  }
});

test("prefix mode accepts what the server's #652 fallback resolves, and only hex", () => {
  for (const ok of [UUID, "F7E1B841", "f7e1b841-4102", "f7e1b84141024e7283bc81cfe4a65129"]) {
    assert.equal(uuid(ok, "article_id", { prefix: true }), null, ok);
  }
  for (const bad of ["f7e1b84", "f7e1-b84", "f7e1b841zz", "", "  ", "#", "..", `${UUID}?x`, "x/y"]) {
    assert.equal(uuid(bad, "article_id", { prefix: true })?.status, 0, JSON.stringify(bad));
  }
  const r = uuid("chain-of-custody", "article_id", { prefix: true });
  assert.match(r.body, /prefix of at least 8 hex digits/);
  assert.doesNotMatch(r.body, /chain-of-custody/, "never echo the value");
  assert.equal(uuid("f7e1b841", "story_id")?.status, 0, "other callers stay full-UUID");
  assert.doesNotMatch(uuid("x", "story_id").body, /prefix/);
});

test("articleId trims, then checks, and hands back the id to interpolate", () => {
  assert.deepEqual(articleId(` ${UUID}\n`), { id: UUID });
  assert.deepEqual(articleId(" f7e1b841 ", { prefix: true }), { id: "f7e1b841" });
  assert.equal(articleId("f7e1b841").refusal?.status, 0, "write verbs take a full UUID");
  assert.equal(articleId(null, { prefix: true }).refusal?.status, 0);
});

test("WIRING: every handler that puts an article id in a path goes through articleId", () => {
  const src = stripComments(readFileSync(join(here, "..", "index.js"), "utf8"));
  assert.doesNotMatch(src, /\$\{article_id\}/, "no raw article_id is interpolated anywhere");
  const prefix = ["knowledgeGet", "knowledgeProgressiveDrill", "knowledgeArticleStats"];
  for (const m of src.matchAll(/\nasync function (\w+)\(/g)) {
    const end = src.indexOf("\nasync function ", m.index + 10);
    const body = src.slice(m.index, end === -1 ? undefined : end);
    if (!/\$\{art\.id\}/.test(body)) continue;
    const opt = prefix.includes(m[1]) ? ", \\{ prefix: true \\}" : "";
    assert.match(
      body,
      new RegExp(`^  const art = articleId\\(article_id${opt}\\);\\n  if \\(art\\.refusal\\) return toContent\\(art\\.refusal\\);`, "m"),
      m[1],
    );
  }
});

test("WIRING, end to end: the real server rescues {id} and sends nothing for a bad id", async () => {
  const seen = [];
  const server = http.createServer((req, res) => {
    seen.push(req.url);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ data: { id: UUID } }));
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const child = spawn(process.execPath, [join(here, "..", "index.js")], {
    env: {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      LOOPCTL_SERVER: `http://127.0.0.1:${server.address().port}`,
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

    send({ id: 3, method: "tools/call", params: { name: "knowledge_get", arguments: { article_id: "f7e1b841" } } });
    const byPrefix = await reply(3);
    assert.notEqual(byPrefix.result?.isError, true, "an 8-hex prefix is sent for the server to resolve");
    assert.ok(seen.some((u) => u.startsWith("/api/v1/articles/f7e1b841")), `requested ${seen}`);

    let rid = 4;
    const refusedCalls = [
      ["knowledge_get", {}],
      ["knowledge_get", { article_id: null }],
      ["knowledge_get", { article_id: "" }],
      ["knowledge_get", { article_id: "#" }],
      ["knowledge_get", { article_id: "x?/y" }],
      ["knowledge_get", { article_id: ".." }],
      ["knowledge_progressive_drill", { id: UUID }],
      ["knowledge_archive", { article_id: "f7e1b841" }],
    ];
    for (const [tool, args] of refusedCalls) {
      const before = seen.length;
      send({ id: rid, method: "tools/call", params: { name: tool, arguments: args } });
      const refused = await reply(rid++);
      assert.equal(refused.result?.isError, true, JSON.stringify(args));
      assert.match(refused.result.content[0].text, /"status": 0/);
      assert.equal(seen.length, before, `nothing may be sent for ${JSON.stringify(args)}`);
    }
  } finally {
    child.kill();
    server.close();
  }
});
