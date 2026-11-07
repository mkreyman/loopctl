/**
 * `escalation_list` (loopctl US-48.11): the request it sends, what it refuses before sending,
 * that its reason_class vocabulary is the server's, and its wiring in index.js and the README.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { escalationList, REASON_CLASSES, ESCALATIONS_PATH } from "../lib/escalations.js";
import { stripComments } from "./tool-surface.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");
const INBOX_SRC = readFileSync(
  path.join(DIR, "..", "..", "lib", "loopctl", "delivery", "escalation_inbox.ex"),
  "utf8",
);

const PROJECT_ID = "6f1c2c1e-5b8a-4f52-9a43-0f7c1b0e2d11";

function fakeApi(response = { ok: true }) {
  const calls = [];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, path: apiPath, body });
    return response;
  };
  return { calls, apiCall };
}

function declaration() {
  const start = INDEX_SRC.indexOf('name: "escalation_list"');
  assert.ok(start > -1, "escalation_list is not declared");
  const end = INDEX_SRC.indexOf("\n  {\n    name: ", start + 1);
  return INDEX_SRC.slice(start, end);
}

describe("escalation_list requests", () => {
  test("a bare call GETs the inbox with no query string", async () => {
    const { calls, apiCall } = fakeApi();

    await escalationList({}, { apiCall });

    assert.deepEqual(calls, [{ method: "GET", path: ESCALATIONS_PATH, body: null }]);
    assert.equal(ESCALATIONS_PATH, "/api/v1/escalations");
  });

  test("every filter and the page controls go on the query string", async () => {
    const { calls, apiCall } = fakeApi();

    await escalationList(
      {
        reason_class: "budget_exhausted",
        project_id: PROJECT_ID,
        since: "2026-11-07T00:00:00Z",
        cursor: "opaque+cursor/=",
        limit: 25,
      },
      { apiCall },
    );

    assert.equal(calls.length, 1);
    const url = new URL(calls[0].path, "http://x");
    assert.equal(url.pathname, ESCALATIONS_PATH);
    assert.equal(url.searchParams.get("reason_class"), "budget_exhausted");
    assert.equal(url.searchParams.get("project_id"), PROJECT_ID);
    assert.equal(url.searchParams.get("since"), "2026-11-07T00:00:00Z");
    // The cursor round-trips byte for byte through the encoding.
    assert.equal(url.searchParams.get("cursor"), "opaque+cursor/=");
    assert.equal(url.searchParams.get("limit"), "25");
  });

  test("refuses the obvious mistakes locally, sending nothing", async () => {
    const { calls, apiCall } = fakeApi();

    for (const args of [
      { reason_class: "budget_reported" },
      { project_id: "not-a-uuid" },
      { project_id: 7 },
      { since: "yesterday-ish" },
      { cursor: 7 },
      { limit: 0 },
      { limit: 2.5 },
    ]) {
      const result = await escalationList(args, { apiCall });
      assert.equal(result.error, true, JSON.stringify(args));
      assert.equal(result.status, 0, JSON.stringify(args));
    }

    assert.equal(calls.length, 0);
  });
});

describe("the reason_class vocabulary", () => {
  test("is exactly the set of classes the server derives (EscalationInbox @reason_classes)", () => {
    const block = INBOX_SRC.match(/@reason_classes %\{([\s\S]*?)\n  \}/);
    assert.ok(block, "@reason_classes was not found in escalation_inbox.ex");

    const server = [...block[1].matchAll(/^\s*[a-z_]+: :([a-z_]+),?$/gm)].map((m) => m[1]);
    // Never vacuous: the map is non-empty, so an anchor that stopped matching fails here.
    assert.ok(server.length > 0, "no edge -> class entries were parsed");

    assert.deepEqual([...new Set(server)].sort(), [...REASON_CLASSES].sort());
    assert.deepEqual(
      [...declaration().matchAll(/^\s*"([a-z_]+)",$/gm)].map((m) => m[1]).sort(),
      [...REASON_CLASSES].sort(),
      "the inputSchema enum drifted from the vocabulary",
    );
  });
});

describe("escalation_list in index.js and the README", () => {
  test("is declared, dispatched to its own handler, and has a README row", () => {
    assert.match(INDEX_SRC, /case "escalation_list":\s*return await escalationListRead\(/);
    assert.ok(
      README.split("\n").some((line) => line.startsWith("| `escalation_list` |")),
      "escalation_list has no row in a README tool table",
    );
  });

  test("its description says it reads only, names resolve_escalation to queued, and its refusals", () => {
    const text = declaration();

    assert.match(text, /READS ONLY/);
    assert.match(text, /resolve_escalation with to: \\"queued\\"/);
    assert.match(text, /LOOPCTL_AGENT_KEY/);
    assert.match(text, /400/);
    assert.match(text, /422/);
    assert.match(text, /No 403/);
  });

  test("its handler passes LOOPCTL_AGENT_KEY as an override, never exactKey", () => {
    const start = INDEX_SRC.indexOf("async function escalationListRead(");
    assert.ok(start > -1, "the escalation_list handler was not found");
    const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
    const handler = stripComments(INDEX_SRC.slice(start, end));

    assert.match(handler, /process\.env\.LOOPCTL_AGENT_KEY/);
    assert.match(handler, /escalationListRequest\(args,/);
    assert.doesNotMatch(handler, /exactKey/);
  });
});
