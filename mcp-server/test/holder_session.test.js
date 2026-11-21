/**
 * US-52.13: the session holder lifecycle — register at startup, the holder credential on
 * every agent-key request, a heartbeat on a timer, end on shutdown — and the wiring of the
 * three holder tools in index.js.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { createHolderSession, heartbeatPath, endPath, HOLDERS_PATH } from "../lib/holder.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const HOLDER = { id: "8e82ea63-e83b-4654-afa8-2df6e0c68aa3", lease_until: "2026-11-21T00:05:00Z" };

function harness({ env = { LOOPCTL_AGENT_KEY: "plain", CLAUDE_SESSION_ID: "s1" }, answers = [], log = () => {} } = {}) {
  const calls = [];
  const timers = [];
  const queue = [...answers];

  const apiCall = async (method, apiPath, body, key, opts) => {
    calls.push({ method, path: apiPath, body, key, opts });
    return queue.length ? queue.shift() : { error: true, status: 0, body: "no answer" };
  };

  const session = createHolderSession({
    apiCall,
    env,
    hostname: () => "minis",
    worktree: () => "/w",
    randomUUID: () => "generated-uuid",
    log,
    setInterval: (fn, ms) => {
      const t = { fn, ms, cleared: false };
      timers.push(t);
      return t;
    },
    clearInterval: (t) => {
      t.cleared = true;
    },
  });

  return { session, calls, timers };
}

const registered = {
  holder: HOLDER,
  credential: { raw_key: "holder-key" },
  heartbeat_seconds: 60,
};

describe("holder session", () => {
  test("registers first, then sends the holder credential, heartbeats and ends", async () => {
    const { session, calls, timers } = harness({
      answers: [registered, { lease_until: "2026-11-21T00:06:00Z", heartbeat_seconds: 60 }, { holder: { ...HOLDER, ended_at: "x" } }],
    });

    assert.equal(session.agentKey(), "plain");
    await session.start();

    assert.equal(calls[0].method, "POST");
    assert.equal(calls[0].path, HOLDERS_PATH);
    assert.equal(calls[0].key, "plain");
    assert.deepEqual(calls[0].opts, { exactKey: true });
    assert.deepEqual(calls[0].body, {
      kind: "interactive",
      session_id: "s1",
      host: "minis",
      worktree: "/w",
    });

    assert.equal(session.agentKey(), "holder-key");

    assert.equal(timers.length, 1);
    assert.equal(timers[0].ms, 60_000);
    await timers[0].fn();
    await new Promise((r) => setImmediate(r));
    assert.equal(calls[1].path, heartbeatPath(HOLDER.id));
    assert.equal(calls[1].key, "holder-key");

    await session.end();
    assert.equal(calls[2].path, endPath(HOLDER.id));
    assert.equal(calls[2].key, "holder-key");
    assert.equal(timers[0].cleared, true);
    assert.equal(session.agentKey(), "plain");
    assert.equal(calls.length, 3);
  });

  test("a failed register keeps the plain key and never throws", async () => {
    const { session } = harness({ answers: [{ error: true, status: 404, body: "not found" }] });
    const result = await session.start();
    assert.equal(result.error, true);
    assert.equal(session.agentKey(), "plain");
  });

  test("a heartbeat refused 401 registers again", async () => {
    const { session, calls } = harness({
      answers: [registered, { error: true, status: 401 }, { ...registered, credential: { raw_key: "k2" } }],
    });
    await session.start();
    await session.heartbeat();
    assert.equal(calls[2].path, HOLDERS_PATH);
    assert.equal(session.agentKey(), "k2");
  });

  test("a network error on heartbeat keeps the credential", async () => {
    const { session } = harness({ answers: [registered, { error: true, status: 0 }] });
    await session.start();
    await session.heartbeat();
    assert.equal(session.agentKey(), "holder-key");
  });

  test("a repeated end sends nothing", async () => {
    const { session, calls } = harness({ answers: [registered, { holder: HOLDER }] });
    await session.start();
    await session.end();
    await session.end();
    assert.equal(calls.length, 2);
  });

  test("prefers CLAUDE_CODE_SESSION_ID, then a generated uuid", () => {
    const specific = harness({ env: { CLAUDE_CODE_SESSION_ID: "a", CLAUDE_SESSION_ID: "b" } });
    assert.equal(specific.session.sessionId, "a");
    const none = harness({ env: {} });
    assert.equal(none.session.sessionId, "generated-uuid");
  });

  test("without LOOPCTL_AGENT_KEY nothing is sent", async () => {
    const { session, calls } = harness({ env: { CLAUDE_SESSION_ID: "s1" } });
    await session.start();
    assert.equal(calls.length, 0);
  });

  test("status never carries the raw credential", async () => {
    const { session } = harness({ answers: [registered] });
    await session.start();
    assert.doesNotMatch(JSON.stringify(session.status()), /holder-key/);
  });
});

describe("a lapsed holder (US-52.19)", () => {
  test("a heartbeat refused holder_lease_expired registers a new holder and logs the lapse", async () => {
    const lines = [];
    const fresh = { holder: { id: "new-holder", lease_until: "x" }, credential: { raw_key: "new-key" }, heartbeat_seconds: 60 };
    const { session, calls, timers } = harness({
      log: (line) => lines.push(line),
      answers: [
        registered,
        { error: true, status: 409, body: { error: { code: "holder_lease_expired" } } },
        fresh,
      ],
    });

    await session.start();
    await timers[0].fn();
    // the timer callback swallows the promise; let it settle
    await new Promise((resolve) => setImmediate(resolve));

    const registers = calls.filter((c) => c.method === "POST" && c.path === HOLDERS_PATH);
    assert.equal(registers.length, 2);
    assert.equal(calls[1].path, heartbeatPath(HOLDER.id));
    assert.equal(session.agentKey(), "new-key");
    assert.equal(session.status().holder.id, "new-holder");
    assert.equal(lines.length, 1);
    assert.match(lines[0], /lapsed/);
    assert.match(lines[0], new RegExp(HOLDER.id));
  });

  test("a raw JSON body is read the same way, and another 409 logs nothing", async () => {
    const lines = [];
    const { session, timers } = harness({
      log: (line) => lines.push(line),
      answers: [
        registered,
        { error: true, status: 409, body: JSON.stringify({ error: { code: "holder_ended" } }) },
        registered,
      ],
    });

    await session.start();
    await timers[0].fn();
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(lines.length, 0);
  });
});

describe("index.js wiring", () => {
  for (const [tool, fn] of [
    ["holder_register", "holderRegisterTool"],
    ["holder_heartbeat", "holderHeartbeatTool"],
    ["holder_end", "holderEndTool"],
  ]) {
    test(`${tool} is declared, dispatched and documented`, () => {
      assert.match(INDEX_SRC, new RegExp(`name: "${tool}"`));
      assert.match(INDEX_SRC, new RegExp(`case "${tool}":\\s*\\n\\s*return await ${fn}\\(\\);`));
      assert.match(README, new RegExp(`\\| \`${tool}\` \\|`));
    });
  }

  test("no request sends LOOPCTL_AGENT_KEY directly; every one goes through agentKey()", () => {
    assert.doesNotMatch(INDEX_SRC, /process\.env\.LOOPCTL_AGENT_KEY/);
  });

  test("registers before serving and ends on stdin close and SIGTERM", () => {
    const start = INDEX_SRC.indexOf("await holderSession.start(");
    const connect = INDEX_SRC.indexOf("await server.connect(transport)");
    assert.ok(start > 0 && start < connect);
    assert.match(INDEX_SRC, /process\.stdin\.on\("close", endHolderAndExit\)/);
    assert.match(INDEX_SRC, /process\.on\("SIGTERM", endHolderAndExit\)/);
  });
});
