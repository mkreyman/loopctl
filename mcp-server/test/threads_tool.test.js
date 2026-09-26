/**
 * US-45.1 on the MCP side: thread_get, thread_checkpoint, thread_entry.
 *
 * Runs the real code in ../lib/threads.js with `apiCall` injected as a recording fake; the
 * last block source-pins index.js and the README so the wiring cannot drift from the logic.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { getThread, recordCheckpoint, recordEntry } from "../lib/threads.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const STORY_ID = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const SHA = "a".repeat(40);
const TREE = "b".repeat(40);
const ENV = {
  LOOPCTL_AGENT_KEY: "agent-key",
  LOOPCTL_ORCH_KEY: "orch-key",
  LOOPCTL_USER_KEY: "user-key",
};

function fakeApi() {
  const calls = [];
  const apiCall = async (method, apiPath, body, key, keyHint) => {
    calls.push({ method, path: apiPath, body, key, keyHint });
    return { ok: true };
  };
  return { calls, apiCall };
}

describe("thread_checkpoint", () => {
  test("POSTs to /thread/checkpoints on the AGENT key, dropping an absent note", async () => {
    const { calls, apiCall } = fakeApi();
    await recordCheckpoint(
      { story_id: STORY_ID, claim_epoch: 4, commit_sha: SHA, tree_sha: TREE },
      { apiCall, env: ENV },
    );

    assert.deepEqual(calls, [
      {
        method: "POST",
        path: `/api/v1/stories/${STORY_ID}/thread/checkpoints`,
        body: { claim_epoch: 4, commit_sha: SHA, tree_sha: TREE },
        key: "agent-key",
        keyHint: "LOOPCTL_AGENT_KEY",
      },
    ]);
  });

  test("refuses client-side without a sha, calling nothing", async () => {
    const { calls, apiCall } = fakeApi();
    const res = await recordCheckpoint(
      { story_id: STORY_ID, claim_epoch: 4, tree_sha: TREE },
      { apiCall, env: ENV },
    );
    assert.equal(res.error, true);
    assert.equal(calls.length, 0);
  });
});

describe("thread_entry", () => {
  const message = {
    story_id: STORY_ID,
    kind: "message",
    idempotency_key: "m1",
    body: "looks right",
    checkpoint_id: "cp",
  };

  test("travels on the agent key by default, sending only the entry's fields", async () => {
    const { calls, apiCall } = fakeApi();
    await recordEntry({ ...message, severity: "high" }, { apiCall, env: ENV });

    assert.equal(calls[0].path, `/api/v1/stories/${STORY_ID}/thread/entries`);
    assert.equal(calls[0].key, "agent-key");
    assert.equal(calls[0].keyHint, "LOOPCTL_AGENT_KEY");
    assert.deepEqual(calls[0].body, {
      kind: "message",
      idempotency_key: "m1",
      body: "looks right",
      checkpoint_id: "cp",
    });
  });

  test("principal user travels on the user key; an unknown principal calls nothing", async () => {
    const { calls, apiCall } = fakeApi();
    await recordEntry({ ...message, principal: "user" }, { apiCall, env: ENV });
    assert.equal(calls[0].key, "user-key");

    const res = await recordEntry({ ...message, principal: "root" }, { apiCall, env: ENV });
    assert.equal(res.error, true);
    assert.equal(calls.length, 1);
  });
});

describe("thread_get", () => {
  test("GETs the thread on the agent key, falling back to the orchestrator key", async () => {
    const { calls, apiCall } = fakeApi();
    await getThread({ story_id: STORY_ID }, { apiCall, env: ENV });
    await getThread(
      { story_id: STORY_ID },
      { apiCall, env: { LOOPCTL_ORCH_KEY: "orch-key" } },
    );

    assert.deepEqual(
      calls.map((c) => [c.method, c.path, c.key]),
      [
        ["GET", `/api/v1/stories/${STORY_ID}/thread`, "agent-key"],
        ["GET", `/api/v1/stories/${STORY_ID}/thread`, "orch-key"],
      ],
    );
  });
});

describe("thread_get paging and keys", () => {
  test("pages with after_seq and limit, and names the key it fell back to", async () => {
    const { calls, apiCall } = fakeApi();
    await getThread(
      { story_id: STORY_ID, after_seq: 4, limit: 2 },
      { apiCall, env: { LOOPCTL_API_KEY: "api-key" } },
    );

    assert.equal(calls[0].path, `/api/v1/stories/${STORY_ID}/thread?after_seq=4&limit=2`);
    assert.equal(calls[0].key, "api-key");
    assert.equal(calls[0].keyHint, "LOOPCTL_API_KEY");
  });

  test("with no key at all, the hint still names the agent key", async () => {
    const { calls, apiCall } = fakeApi();
    await getThread({ story_id: STORY_ID }, { apiCall, env: {} });
    assert.equal(calls[0].keyHint, "LOOPCTL_AGENT_KEY");
  });
});

describe("wiring", () => {
  for (const [tool, handler] of [
    ["thread_get", "threadGet"],
    ["thread_checkpoint", "threadCheckpoint"],
    ["thread_entry", "threadEntry"],
  ]) {
    test(`${tool} is declared, dispatched and documented`, () => {
      assert.ok(INDEX_SRC.includes(`name: "${tool}"`), `${tool} not declared`);
      assert.ok(
        INDEX_SRC.includes(`case "${tool}":\n      return await ${handler}(args);`),
        `${tool} not dispatched`,
      );
      assert.ok(README.includes(`| \`${tool}\` |`), `${tool} has no README row`);
      assert.ok(
        INDEX_SRC.includes("apiCall(method, path, body, key, { exactKey: true, keyHint })"),
        "thread calls must pass their keyHint",
      );
    });
  }
});
