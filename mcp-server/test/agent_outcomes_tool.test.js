/**
 * loopctl US-48.12 on the MCP side: `agent_outcomes`, the read of an agent spec's track record
 * from the run-outcome ledger (`GET /api/v1/agent_specs/:spec_id/outcomes`).
 *
 * The request shape is tested against the lib module; the last block source-pins index.js so
 * the tool cannot be declared and not dispatched, dispatched to another handler, keyed with
 * another key, or left without its README row.
 *
 * Run: node --test test/agent_outcomes_tool.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { agentOutcomes, agentOutcomesPath, MAX_WINDOW_DAYS } from "../lib/agent-outcomes.js";
import { stripComments } from "./tool-surface.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

function fakeApi(response = { ok: true }) {
  const calls = [];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, path: apiPath, body });
    return response;
  };
  return { calls, apiCall };
}

describe("agent_outcomes (US-48.12)", () => {
  test("GETs the spec's outcome summary, and nothing else", async () => {
    const { calls, apiCall } = fakeApi();

    await agentOutcomes({ spec_id: "triage" }, { apiCall });

    assert.equal(calls.length, 1);
    assert.equal(calls[0].method, "GET");
    assert.equal(calls[0].path, "/api/v1/agent_specs/triage/outcomes");
    assert.equal(calls[0].body, null);
  });

  test("carries window_days as a query parameter", async () => {
    const { calls, apiCall } = fakeApi();

    await agentOutcomes({ spec_id: "reply_draft", window_days: 7 }, { apiCall });

    assert.equal(calls[0].path, `${agentOutcomesPath("reply_draft")}?window_days=7`);
  });

  test("returns the server's answer as it came", async () => {
    const answer = { data: { spec_id: "implement", versions: [] } };
    const { apiCall } = fakeApi(answer);

    assert.deepEqual(await agentOutcomes({ spec_id: "implement" }, { apiCall }), answer);
  });

  test("refuses locally, sending nothing, for a bad spec_id or window_days", async () => {
    const { calls, apiCall } = fakeApi();

    for (const args of [
      {},
      { spec_id: "" },
      { spec_id: "Triage" },
      { spec_id: "../stories" },
      { spec_id: "triage", window_days: 0 },
      { spec_id: "triage", window_days: MAX_WINDOW_DAYS + 1 },
      { spec_id: "triage", window_days: 1.5 },
      { spec_id: "triage", window_days: "7" },
    ]) {
      const refused = await agentOutcomes(args, { apiCall });
      assert.equal(refused.error, true, `${JSON.stringify(args)} was not refused`);
      assert.equal(refused.status, 0, "a local refusal must not claim a server answered");
    }

    assert.equal(calls.length, 0);
  });
});

describe("agent_outcomes wiring in index.js", () => {
  test("declared, dispatched to its own handler, and given a README row", () => {
    assert.ok(INDEX_SRC.includes('name: "agent_outcomes"'), "agent_outcomes is not declared");
    assert.match(
      INDEX_SRC,
      /case "agent_outcomes":\s*return await agentOutcomesRead\(/,
      "agent_outcomes is not dispatched to agentOutcomesRead()",
    );
    assert.ok(
      README.split("\n").some((line) => line.startsWith("| `agent_outcomes` |")),
      "agent_outcomes has no row in a README tool table",
    );
  });

  test("its description says what it refuses and which key it uses", () => {
    const start = INDEX_SRC.indexOf('name: "agent_outcomes"');
    const declaration = INDEX_SRC.slice(start, INDEX_SRC.indexOf("inputSchema:", start));

    assert.match(declaration, /REFUSES/);
    assert.match(declaration, /400/);
    assert.match(declaration, /LOOPCTL_AGENT_KEY/);
  });

  test("its handler passes LOOPCTL_AGENT_KEY as an override, never pinned", () => {
    const start = INDEX_SRC.indexOf("async function agentOutcomesRead(");
    assert.ok(start > -1, "the agent_outcomes handler was not found");
    const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
    assert.ok(end > start, "the handler has no following function to bound it");
    const handler = stripComments(INDEX_SRC.slice(start, end));

    assert.match(handler, /process\.env\.LOOPCTL_AGENT_KEY/);
    assert.match(handler, /agentOutcomes\(args,/);
    assert.doesNotMatch(handler, /exactKey/);
  });
});
