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

import {
  getReview,
  getThread,
  placeReview,
  recordCheckpoint,
  recordEntry,
  recordFinding,
  recordFix,
  recordVerdict,
} from "../lib/threads.js";

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

  test("travels on the key claim_story claims with: LOOPCTL_API_KEY wins when set", async () => {
    const { calls, apiCall } = fakeApi();
    await recordCheckpoint(
      { story_id: STORY_ID, claim_epoch: 4, commit_sha: SHA, tree_sha: TREE },
      { apiCall, env: { ...ENV, LOOPCTL_API_KEY: "api-key" } },
    );
    assert.equal(calls[0].key, "api-key");
    assert.equal(calls[0].keyHint, "LOOPCTL_API_KEY");
  });

  test("refuses client-side without claim_epoch, calling nothing", async () => {
    const { calls, apiCall } = fakeApi();
    const res = await recordCheckpoint(
      { story_id: STORY_ID, commit_sha: SHA, tree_sha: TREE },
      { apiCall, env: ENV },
    );
    assert.equal(res.error, true);
    assert.match(res.body, /claim_epoch/);
    assert.equal(calls.length, 0);
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
    ["thread_place_review", "threadPlaceReview"],
    ["thread_review_get", "threadReviewGet"],
    ["thread_finding", "threadFinding"],
    ["thread_verdict", "threadVerdict"],
    ["thread_fix", "threadFix"],
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

// --- US-45.3: review on the thread -------------------------------------------------------

const REVIEW_ID = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";
const FINDING_ID = "6ba7b810-9dad-41d1-80b4-00c04fd430c8";

describe("thread_place_review", () => {
  test("POSTs to /thread/reviews on the ORCHESTRATOR key, dropping absent options", async () => {
    const { calls, apiCall } = fakeApi();
    await placeReview({ story_id: STORY_ID, agent_id: "agent-1" }, { apiCall, env: ENV });

    assert.deepEqual(calls, [
      {
        method: "POST",
        path: `/api/v1/stories/${STORY_ID}/thread/reviews`,
        body: { agent_id: "agent-1" },
        key: "orch-key",
        keyHint: "LOOPCTL_ORCH_KEY",
      },
    ]);
  });

  test("principal user travels on the user key; an agent principal calls nothing", async () => {
    const { calls, apiCall } = fakeApi();
    await placeReview(
      { story_id: STORY_ID, agent_id: "a", principal: "user" },
      { apiCall, env: ENV },
    );
    assert.equal(calls[0].key, "user-key");

    const refused = await placeReview(
      { story_id: STORY_ID, agent_id: "a", principal: "agent" },
      { apiCall, env: ENV },
    );
    assert.equal(refused.error, true);
    assert.equal(calls.length, 1);
  });

  test("refuses client-side without agent_id, calling nothing", async () => {
    const { calls, apiCall } = fakeApi();
    const result = await placeReview({ story_id: STORY_ID }, { apiCall, env: ENV });
    assert.equal(result.error, true);
    assert.equal(calls.length, 0);
  });
});

describe("thread_finding and thread_verdict", () => {
  test("travel ONLY on LOOPCTL_API_KEY, never the agent key", async () => {
    const { calls, apiCall } = fakeApi();
    const env = { ...ENV, LOOPCTL_API_KEY: "review-key" };

    await recordFinding(
      { story_id: STORY_ID, idempotency_key: "f", body: "b", severity: "high" },
      { apiCall, env },
    );
    await recordVerdict({ story_id: STORY_ID, idempotency_key: "v", body: "done" }, { apiCall, env });

    assert.deepEqual(
      calls.map((c) => [c.path, c.key, c.keyHint]),
      [
        [`/api/v1/stories/${STORY_ID}/thread/findings`, "review-key", "LOOPCTL_API_KEY"],
        [`/api/v1/stories/${STORY_ID}/thread/verdicts`, "review-key", "LOOPCTL_API_KEY"],
      ],
    );
    assert.deepEqual(calls[0].body, { idempotency_key: "f", body: "b", severity: "high" });
  });

  test("with no LOOPCTL_API_KEY the key is absent, not the implementer's", async () => {
    const { calls, apiCall } = fakeApi();
    await recordFinding(
      { story_id: STORY_ID, idempotency_key: "f", body: "b", severity: "low" },
      { apiCall, env: ENV },
    );
    assert.equal(calls[0].key, undefined);
    assert.equal(calls[0].keyHint, "LOOPCTL_API_KEY");
  });

  test("a finding without a severity calls nothing", async () => {
    const { calls, apiCall } = fakeApi();
    const result = await recordFinding(
      { story_id: STORY_ID, idempotency_key: "f", body: "b" },
      { apiCall, env: ENV },
    );
    assert.equal(result.error, true);
    assert.equal(calls.length, 0);
  });
});

describe("thread_fix", () => {
  const fix = {
    story_id: STORY_ID,
    claim_epoch: 3,
    checkpoint_id: "cp",
    finding_ids: [FINDING_ID],
    idempotency_key: "x",
    body: "why",
  };

  test("POSTs to /thread/fixes on the key claim_story claims with", async () => {
    const { calls, apiCall } = fakeApi();
    await recordFix(fix, { apiCall, env: ENV });
    await recordFix(fix, { apiCall, env: { ...ENV, LOOPCTL_API_KEY: "api-key" } });

    assert.equal(calls[0].path, `/api/v1/stories/${STORY_ID}/thread/fixes`);
    assert.equal(calls[0].key, "agent-key");
    assert.equal(calls[1].key, "api-key");
    assert.deepEqual(calls[0].body, {
      claim_epoch: 3,
      checkpoint_id: "cp",
      finding_ids: [FINDING_ID],
      idempotency_key: "x",
      body: "why",
    });
  });

  test("refuses client-side with no findings or no claim_epoch, calling nothing", async () => {
    const { calls, apiCall } = fakeApi();
    assert.equal((await recordFix({ ...fix, finding_ids: [] }, { apiCall, env: ENV })).error, true);
    assert.equal(
      (await recordFix({ ...fix, claim_epoch: undefined }, { apiCall, env: ENV })).error,
      true,
    );
    assert.equal(calls.length, 0);
  });
});

describe("thread_review_get", () => {
  test("GETs the review payload on LOOPCTL_API_KEY first", async () => {
    const { calls, apiCall } = fakeApi();
    await getReview(
      { story_id: STORY_ID, review_id: REVIEW_ID },
      { apiCall, env: { ...ENV, LOOPCTL_API_KEY: "review-key" } },
    );
    await getReview({ story_id: STORY_ID, review_id: REVIEW_ID }, { apiCall, env: ENV });

    assert.equal(calls[0].path, `/api/v1/stories/${STORY_ID}/thread/reviews/${REVIEW_ID}`);
    assert.equal(calls[0].key, "review-key");
    assert.equal(calls[1].key, "agent-key");
  });
});
