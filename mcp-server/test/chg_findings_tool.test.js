/**
 * loopctl US-51.6 on the MCP side (AC-51.6.2, AC-51.6.4): `chg_findings` (GET
 * /api/v1/chg_findings) and `chg_finding_clear` (POST /api/v1/chg_findings/:id/clear).
 *
 * The request shapes are tested against the lib module; the last block source-pins index.js so
 * neither tool can be declared and not dispatched, dispatched to another handler, keyed with
 * the wrong key, or left without its README row.
 *
 * Run: node --test test/chg_findings_tool.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  chgFindings,
  chgFindingClear,
  chgFindingDismiss,
  DISMISS_REASON_MAX,
  LIST_CAP,
} from "../lib/chg-findings.js";
import { stripComments } from "./tool-surface.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const ID = "0b9e6c1e-6a38-4f6b-9a1f-0d1c2b3a4f5e";

function fakeApi(response = { ok: true }, extra = {}) {
  const calls = [];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, path: apiPath, body });
    return response;
  };
  return { calls, apiCall, ...extra };
}

function handler(name) {
  const start = INDEX_SRC.indexOf(`async function ${name}(`);
  assert.ok(start > -1, `${name} was not found`);
  const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
  assert.ok(end > start, `${name} has no following function to bound it`);
  return stripComments(INDEX_SRC.slice(start, end));
}

describe("chg_findings (US-51.6)", () => {
  test("GETs the list with no query when no filter is given", async () => {
    const api = fakeApi();

    await chgFindings({}, api);

    assert.deepEqual(api.calls, [{ method: "GET", path: "/api/v1/chg_findings", body: null }]);
  });

  test("carries every filter as a query parameter", async () => {
    const api = fakeApi();

    await chgFindings(
      { state: "escalated", kind: "flaky_test", repo: "mkreyman/chg", limit: LIST_CAP },
      api,
    );

    const url = new URL(`http://x${api.calls[0].path}`);
    assert.equal(url.pathname, "/api/v1/chg_findings");
    assert.equal(url.searchParams.get("state"), "escalated");
    assert.equal(url.searchParams.get("kind"), "flaky_test");
    assert.equal(url.searchParams.get("repo"), "mkreyman/chg");
    assert.equal(url.searchParams.get("limit"), String(LIST_CAP));
  });

  test("refuses locally, sending nothing, for a bad filter", async () => {
    const api = fakeApi();

    for (const args of [
      { state: "open" },
      { kind: "bug" },
      { repo: 7 },
      { limit: 0 },
      { limit: LIST_CAP + 1 },
      { limit: "10" },
    ]) {
      const refused = await chgFindings(args, api);
      assert.equal(refused.error, true, `${JSON.stringify(args)} was not refused`);
      assert.equal(refused.status, 0);
    }

    assert.equal(api.calls.length, 0);
  });
});

describe("chg_finding_clear (US-51.6)", () => {
  test("POSTs to the finding's clear path with the user key", async () => {
    const api = fakeApi({ data: { state: "queued" } }, { userKey: "user-key" });

    assert.deepEqual(await chgFindingClear({ finding_id: ID }, api), { data: { state: "queued" } });
    assert.deepEqual(api.calls, [
      { method: "POST", path: `/api/v1/chg_findings/${ID}/clear`, body: {} },
    ]);
  });

  test("refuses locally without a user key or a UUID", async () => {
    const api = fakeApi({}, { userKey: "user-key" });
    const noKey = fakeApi();

    assert.equal((await chgFindingClear({ finding_id: ID }, noKey)).error, true);
    assert.equal((await chgFindingClear({ finding_id: "nope" }, api)).error, true);
    assert.equal((await chgFindingClear({}, api)).error, true);
    assert.equal(api.calls.length + noKey.calls.length, 0);
  });
});

describe("chg_finding_dismiss (#1064)", () => {
  test("POSTs the reason to the finding's dismiss path with the user key", async () => {
    const api = fakeApi({ data: { state: "closed" } }, { userKey: "user-key" });

    assert.deepEqual(await chgFindingDismiss({ finding_id: ID, reason: "hook row" }, api), {
      data: { state: "closed" },
    });
    assert.deepEqual(api.calls, [
      { method: "POST", path: `/api/v1/chg_findings/${ID}/dismiss`, body: { reason: "hook row" } },
    ]);
  });

  test("refuses locally without a user key, a UUID, or a 1..500 character reason", async () => {
    const api = fakeApi({}, { userKey: "user-key" });
    const noKey = fakeApi();

    assert.equal((await chgFindingDismiss({ finding_id: ID, reason: "x" }, noKey)).error, true);
    assert.equal((await chgFindingDismiss({ finding_id: "nope", reason: "x" }, api)).error, true);
    assert.equal((await chgFindingDismiss({ finding_id: ID }, api)).error, true);
    assert.equal((await chgFindingDismiss({ finding_id: ID, reason: "  " }, api)).error, true);
    assert.equal(
      (await chgFindingDismiss({ finding_id: ID, reason: "x".repeat(DISMISS_REASON_MAX + 1) }, api))
        .error,
      true,
    );
    assert.equal(api.calls.length + noKey.calls.length, 0);
  });
});

describe("chg findings wiring in index.js", () => {
  test("the tools are declared, dispatched to their own handlers, and given README rows", () => {
    for (const [tool, fn] of [
      ["chg_findings", "chgFindingsRead"],
      ["chg_finding_clear", "chgFindingClearCall"],
      ["chg_finding_dismiss", "chgFindingDismissCall"],
    ]) {
      assert.ok(INDEX_SRC.includes(`name: "${tool}"`), `${tool} is not declared`);
      assert.match(
        INDEX_SRC,
        new RegExp(`case "${tool}":\\s*return await ${fn}\\(`),
        `${tool} is not dispatched to ${fn}()`,
      );
      assert.ok(
        README.split("\n").some((line) => line.startsWith(`| \`${tool}\` |`)),
        `${tool} has no row in a README tool table`,
      );
    }
  });

  test("the list reads with LOOPCTL_AGENT_KEY as an override, never pinned", () => {
    const body = handler("chgFindingsRead");

    assert.match(body, /agentKey\(\)/);
    assert.match(body, /chgFindings\(args,/);
    assert.doesNotMatch(body, /exactKey/);
  });

  test("clear goes through runnerDeps(), the exact user key", () => {
    assert.match(handler("chgFindingClearCall"), /chgFindingClear\(args, runnerDeps\(\)\)/);
  });

  test("clear's description names what it refuses and the key it needs", () => {
    const start = INDEX_SRC.indexOf('name: "chg_finding_clear"');
    const declaration = INDEX_SRC.slice(start, INDEX_SRC.indexOf("inputSchema:", start));

    for (const word of ["not_escalated", "404", "403", "custody_tier_required", "LOOPCTL_USER_KEY"]) {
      assert.ok(declaration.includes(word), `the description does not name ${word}`);
    }
  });

  test("dismiss goes through runnerDeps() and its description names its refusals", () => {
    assert.match(handler("chgFindingDismissCall"), /chgFindingDismiss\(args, runnerDeps\(\)\)/);

    const start = INDEX_SRC.indexOf('name: "chg_finding_dismiss"');
    const declaration = INDEX_SRC.slice(start, INDEX_SRC.indexOf("inputSchema:", start));

    for (const word of [
      "invalid_reason",
      "not_dismissible",
      "filing_in_flight",
      "404",
      "custody_tier_required",
      "LOOPCTL_USER_KEY",
    ]) {
      assert.ok(declaration.includes(word), `the description does not name ${word}`);
    }
  });
});
