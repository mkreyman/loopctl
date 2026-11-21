/**
 * loopctl US-50.6 on the MCP side (TC-50.6.3): `chg_ledger_summary`, the read of the chg
 * ledger summary (`GET /api/v1/chg_ledger/summary`).
 *
 * The request shape is tested against the lib module; the last block source-pins index.js so
 * the tool cannot be declared and not dispatched, dispatched to another handler, keyed with
 * another key, or left without its README row.
 *
 * Run: node --test test/chg_ledger_summary_tool.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { chgLedgerSummary, MAX_PERIOD_DAYS } from "../lib/chg-ledger-summary.js";
import { stripComments } from "./tool-surface.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const NOW = Date.parse("2026-11-18T12:00:00Z");
const DAY = 86_400_000;

function fakeApi(response = { ok: true }) {
  const calls = [];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, path: apiPath, body });
    return response;
  };
  return { calls, apiCall, now: () => NOW };
}

describe("chg_ledger_summary (US-50.6)", () => {
  test("GETs the summary with no query when no filter is given", async () => {
    const api = fakeApi();

    await chgLedgerSummary({}, api);

    assert.equal(api.calls.length, 1);
    assert.equal(api.calls[0].method, "GET");
    assert.equal(api.calls[0].path, "/api/v1/chg_ledger/summary");
    assert.equal(api.calls[0].body, null);
  });

  test("carries every filter as an encoded query parameter", async () => {
    const api = fakeApi();

    await chgLedgerSummary(
      {
        repo: "mkreyman/loopctl",
        host: "minis",
        since: "2026-11-01T00:00:00Z",
        until: "2026-11-18T00:00:00Z",
      },
      api,
    );

    const url = new URL(`http://x${api.calls[0].path}`);
    assert.equal(url.pathname, "/api/v1/chg_ledger/summary");
    assert.equal(url.searchParams.get("repo"), "mkreyman/loopctl");
    assert.equal(url.searchParams.get("host"), "minis");
    assert.equal(url.searchParams.get("since"), "2026-11-01T00:00:00Z");
    assert.equal(url.searchParams.get("until"), "2026-11-18T00:00:00Z");
  });

  test("returns the server's answer as it came", async () => {
    const answer = { data: { gate_outcomes: [] } };
    const api = fakeApi(answer);

    assert.deepEqual(await chgLedgerSummary({}, api), answer);
  });

  test("exactly the period cap is sent", async () => {
    const api = fakeApi();
    const since = new Date(NOW - MAX_PERIOD_DAYS * DAY).toISOString();

    await chgLedgerSummary({ since }, api);
    assert.equal(api.calls.length, 1);
  });

  test("refuses locally, sending nothing, for bad filters or an over-cap period", async () => {
    const api = fakeApi();

    for (const args of [
      { repo: 7 },
      { host: ["minis"] },
      { since: "yesterday" },
      { until: "not a time" },
      { since: new Date(NOW - (MAX_PERIOD_DAYS * DAY + 1000)).toISOString() },
      { since: "2026-11-10T00:00:00Z", until: "2026-11-09T00:00:00Z" },
      { since: new Date(NOW - 120 * DAY).toISOString() },
    ]) {
      const refused = await chgLedgerSummary(args, api);
      assert.equal(refused.error, true, `${JSON.stringify(args)} was not refused`);
      assert.equal(refused.status, 0, "a local refusal must not claim a server answered");
    }

    assert.equal(api.calls.length, 0);
  });
});

describe("chg_ledger_summary wiring in index.js", () => {
  test("declared, dispatched to its own handler, and given a README row", () => {
    assert.ok(INDEX_SRC.includes('name: "chg_ledger_summary"'), "not declared");
    assert.match(
      INDEX_SRC,
      /case "chg_ledger_summary":\s*return await chgLedgerSummaryRead\(/,
      "chg_ledger_summary is not dispatched to chgLedgerSummaryRead()",
    );
    assert.ok(
      README.split("\n").some((line) => line.startsWith("| `chg_ledger_summary` |")),
      "chg_ledger_summary has no row in a README tool table",
    );
  });

  test("its description names the filters, what it refuses and which key it uses", () => {
    const start = INDEX_SRC.indexOf('name: "chg_ledger_summary"');
    const declaration = INDEX_SRC.slice(start, INDEX_SRC.indexOf("inputSchema:", start));

    for (const word of ["`repo`", "`host`", "`since`", "`until`", "REFUSES", "422", "90 days"]) {
      assert.ok(declaration.includes(word), `the description does not name ${word}`);
    }
    assert.match(declaration, /LOOPCTL_AGENT_KEY/);
  });

  test("its handler passes LOOPCTL_AGENT_KEY as an override, never pinned", () => {
    const start = INDEX_SRC.indexOf("async function chgLedgerSummaryRead(");
    assert.ok(start > -1, "the chg_ledger_summary handler was not found");
    const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
    assert.ok(end > start, "the handler has no following function to bound it");
    const handler = stripComments(INDEX_SRC.slice(start, end));

    assert.match(handler, /agentKey\(\)/);
    assert.match(handler, /chgLedgerSummary\(args,/);
    assert.doesNotMatch(handler, /exactKey/);
  });
});
