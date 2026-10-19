/**
 * loopctl US-47.7 on the MCP side: `change_binding_get`, the read of
 * `GET /api/v1/stories/:id/changes`.
 *
 * TC-47.7.1 (wiring): declared, dispatched to its own handler, and listed in the README — a
 * tool declared and not dispatched, or dispatched to another handler, is the reachability
 * defect loopctl's CLAUDE.md names, one layer inside the MCP server. AC-47.7.3: the
 * description states what the endpoint refuses and which key it needs.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { changeBindingGet, storyChangesPath } from "../lib/change-bindings.js";
import { stripComments } from "./tool-surface.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const STORY_ID = "d9975b31-032d-4f44-b154-c48af09640c7";

function fakeApi(response = { bindings: [] }) {
  const calls = [];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, path: apiPath, body });
    return response;
  };
  return { calls, apiCall };
}

describe("change_binding_get", () => {
  test("GETs the story's changes and returns the server's answer as is", async () => {
    const answer = { story_id: STORY_ID, bindings: [], binding_count: 0 };
    const { calls, apiCall } = fakeApi(answer);

    const result = await changeBindingGet({ story_id: STORY_ID }, { apiCall });

    assert.deepEqual(calls, [
      { method: "GET", path: `/api/v1/stories/${STORY_ID}/changes`, body: null },
    ]);
    assert.equal(result, answer);
  });

  test("the path is encoded, and is the route the router serves", () => {
    assert.equal(storyChangesPath(STORY_ID), `/api/v1/stories/${STORY_ID}/changes`);

    const routes = JSON.parse(readFileSync(path.join(DIR, "router-routes.json"), "utf8")).routes;
    assert.ok(
      routes.some(([verb, p]) => verb === "GET" && p === "/api/v1/stories/:id/changes"),
      "GET /api/v1/stories/:id/changes is not in the router snapshot",
    );
  });

  test("refuses a missing or malformed story_id locally, sending nothing", async () => {
    for (const args of [{}, { story_id: "" }, { story_id: "not-a-uuid" }, { story_id: 42 }]) {
      const { calls, apiCall } = fakeApi();
      const result = await changeBindingGet(args, { apiCall });

      assert.equal(result.error, true, `accepted ${JSON.stringify(args)}`);
      assert.equal(result.status, 0, "a local refusal must not look like a server answer");
      assert.equal(calls.length, 0, `sent a request for ${JSON.stringify(args)}`);
    }
  });
});

describe("the declaration states what the endpoint refuses and which key it needs", () => {
  const start = INDEX_SRC.indexOf('name: "change_binding_get"');
  const end = INDEX_SRC.indexOf('required: ["story_id"]', start);
  const declaration = INDEX_SRC.slice(start, end);

  test("it is declared, bounded by its own inputSchema", () => {
    assert.ok(start > -1, "change_binding_get is not declared in index.js");
    assert.ok(end > start, "the declaration has no inputSchema to bound it");
  });

  test("it names the 404 and says a foreign story answers like an unknown one", () => {
    assert.match(declaration, /404/);
    assert.match(declaration, /another tenant's id answers exactly like an unknown one/);
  });

  test("it names the 401 and the 400, and says no role is refused", () => {
    assert.match(declaration, /401/);
    assert.match(declaration, /400 for a superadmin key without/);
    assert.match(declaration, /No 403/);
  });

  test("it names the key and the role gate", () => {
    assert.match(declaration, /LOOPCTL_AGENT_KEY/);
    assert.match(declaration, /role: :agent/);
  });

  test("it says the lists are bounded and where the bounds are", () => {
    assert.match(declaration, /max_events_per_change/);
    assert.match(declaration, /max_bindings/);
    assert.match(declaration, /events_truncated/);
  });
});

describe("the wiring in index.js (TC-47.7.1)", () => {
  test("declared, dispatched TO ITS OWN HANDLER, and documented", () => {
    assert.ok(INDEX_SRC.includes('name: "change_binding_get"'), "not declared");
    assert.match(
      INDEX_SRC,
      /case "change_binding_get":\s*return await changeBindingGet\(/,
      "change_binding_get is not dispatched to changeBindingGet()",
    );
    assert.ok(
      README.split("\n").some((line) => line.startsWith("| `change_binding_get` |")),
      "change_binding_get has no row in a README tool table",
    );
  });

  test("the handler forwards to the request module on the agent key", () => {
    const start = INDEX_SRC.indexOf("async function changeBindingGet(");
    assert.ok(start > -1, "the change_binding_get handler was not found");
    const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
    assert.ok(end > start, "the handler has no following function to bound it");

    // Comments stripped: the handler's comment names the same identifiers, so a commented-
    // out wiring would otherwise still match.
    const handler = stripComments(INDEX_SRC.slice(start, end));
    assert.match(handler, /changeBindingGetRequest\(args,/);
    assert.match(handler, /process\.env\.LOOPCTL_AGENT_KEY/);
    assert.match(handler, /apiCall\(method, path, body, key\)/);
  });
});
