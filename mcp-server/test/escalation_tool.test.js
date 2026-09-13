/**
 * #803 on the MCP side: escalate_story.
 *
 * Runs the real code in ../lib/escalation.js with `apiCall` injected as a recording fake;
 * the last block source-pins index.js so the wiring cannot drift from the logic.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { escalateStory, escalatePath, escalationNotice } from "../lib/escalation.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const STORY_ID = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const ENV = {
  LOOPCTL_AGENT_KEY: "agent-key",
  LOOPCTL_ORCH_KEY: "orch-key",
  LOOPCTL_USER_KEY: "user-key",
};

function fakeApi(response = { stage: { story_id: STORY_ID, stage: "escalated" } }) {
  const calls = [];
  const apiCall = async (method, apiPath, body, key) => {
    calls.push({ method, path: apiPath, body, key });
    return response;
  };
  return { calls, apiCall };
}

describe("escalate_story", () => {
  test("POSTs to /stories/:id/escalate on the AGENT key", async () => {
    const { calls, apiCall } = fakeApi();
    await escalateStory(
      { story_id: STORY_ID, claim_epoch: 7, reason: "contradicts US-3.1" },
      { apiCall, env: ENV },
    );

    assert.deepEqual(calls, [
      {
        method: "POST",
        path: `/api/v1/stories/${STORY_ID}/escalate`,
        body: { claim_epoch: 7, reason: "contradicts US-3.1" },
        key: "agent-key",
      },
    ]);
  });

  test("never travels on the orchestrator or user key: the endpoint is exact_role agent", async () => {
    // The human key RESOLVES an escalation; sending on it would 403, and worse, a hierarchy
    // gate here would let one key manufacture the escalation it then resolves.
    const { calls, apiCall } = fakeApi();
    await escalateStory(
      { story_id: STORY_ID, claim_epoch: 1, reason: "why" },
      { apiCall, env: ENV },
    );
    assert.equal(calls[0].key, ENV.LOOPCTL_AGENT_KEY);
    assert.notEqual(calls[0].key, ENV.LOOPCTL_ORCH_KEY);
    assert.notEqual(calls[0].key, ENV.LOOPCTL_USER_KEY);
  });

  test("reads LOOPCTL_AGENT_KEY from process.env when no env is injected (the index.js path)", async () => {
    const saved = process.env.LOOPCTL_AGENT_KEY;
    process.env.LOOPCTL_AGENT_KEY = "process-agent-key";
    try {
      const { calls, apiCall } = fakeApi();
      await escalateStory({ story_id: STORY_ID, claim_epoch: 1, reason: "why" }, { apiCall });
      assert.equal(calls[0].key, "process-agent-key");
    } finally {
      if (saved === undefined) delete process.env.LOOPCTL_AGENT_KEY;
      else process.env.LOOPCTL_AGENT_KEY = saved;
    }
  });

  test("sends payload when given and omits the key entirely when not", async () => {
    const { calls, apiCall } = fakeApi();
    await escalateStory(
      { story_id: STORY_ID, claim_epoch: 0, reason: "why", payload: { contradicts: ["US-3.1"] } },
      { apiCall, env: ENV },
    );
    await escalateStory({ story_id: STORY_ID, claim_epoch: 0, reason: "why" }, { apiCall, env: ENV });
    await escalateStory(
      { story_id: STORY_ID, claim_epoch: 0, reason: "why", payload: null },
      { apiCall, env: ENV },
    );

    assert.deepEqual(calls[0].body.payload, { contradicts: ["US-3.1"] });
    assert.equal("payload" in calls[1].body, false);
    assert.equal("payload" in calls[2].body, false);
  });

  test("forwards epoch 0 and a malformed epoch unchanged, for the server to judge", async () => {
    const { calls, apiCall } = fakeApi();
    await escalateStory({ story_id: STORY_ID, claim_epoch: 0, reason: "why" }, { apiCall, env: ENV });
    await escalateStory({ story_id: STORY_ID, claim_epoch: "3", reason: "why" }, { apiCall, env: ENV });
    assert.deepEqual(
      calls.map((c) => c.body.claim_epoch),
      [0, "3"],
    );
  });

  for (const [status, code] of [
    [400, "bad_request"],
    [409, "stale_claim_epoch"],
    [409, "not_claimant"],
    [409, "stale_stage"],
    [404, "unknown_story_stage"],
    [403, "custody_tier_required"],
  ]) {
    test(`passes a ${status} ${code} through unchanged`, async () => {
      const failure = { error: true, status, body: { error: { status, code, message: "no" } } };
      const { apiCall } = fakeApi(failure);
      const result = await escalateStory(
        { story_id: STORY_ID, claim_epoch: 2, reason: "why" },
        { apiCall, env: ENV },
      );
      assert.deepEqual(result, failure);
    });
  }

  test("requires story_id and a non-empty reason, and calls nothing without them", async () => {
    const { calls, apiCall } = fakeApi();

    for (const args of [
      { claim_epoch: 1, reason: "why" },
      { story_id: "   ", claim_epoch: 1, reason: "why" },
      { story_id: STORY_ID, claim_epoch: 1 },
      { story_id: STORY_ID, claim_epoch: 1, reason: "   " },
      { story_id: STORY_ID, claim_epoch: 1, reason: 42 },
    ]) {
      const result = await escalateStory(args, { apiCall, env: ENV });
      assert.equal(result.error, true);
    }

    assert.deepEqual(calls, []);
  });

  test("encodes the story id into the path", () => {
    assert.equal(escalatePath("a/b"), "/api/v1/stories/a%2Fb/escalate");
  });
});

describe("escalationNotice", () => {
  test("tells the session to STOP on a successful escalation", () => {
    const notice = escalationNotice({ stage: { stage: "escalated", claim_epoch: 4 } });
    assert.match(notice, /STOP working it now/);
    assert.match(notice, /only a human moves it off/);
  });

  test("is null on a refusal, on an older server, and on a stage that is not escalated", () => {
    assert.equal(escalationNotice({ error: true, status: 409, body: {} }), null);
    assert.equal(escalationNotice({ story: { id: STORY_ID } }), null);
    assert.equal(escalationNotice({ stage: { stage: "implementing" } }), null);
    assert.equal(escalationNotice(undefined), null);
  });
});

describe("index.js wiring", () => {
  function functionSource(name) {
    const declaration = `function ${name}(`;
    const start = INDEX_SRC.indexOf(declaration);
    assert.notEqual(start, -1, `index.js must define ${declaration}`);
    const rest = INDEX_SRC.slice(start + declaration.length);
    return rest.slice(0, rest.indexOf("\n}\n"));
  }

  test("escalate_story is declared with its three required args, dispatched, and documented", () => {
    const start = INDEX_SRC.indexOf('name: "escalate_story",');
    assert.notEqual(start, -1);
    const decl = INDEX_SRC.slice(start, INDEX_SRC.indexOf("\n  },\n  {", start));
    assert.match(decl, /claim_epoch: \{\s*type: "integer"/);
    assert.match(decl, /reason: \{\s*type: "string"/);
    assert.match(decl, /required: \["story_id", "claim_epoch", "reason"\]/);
    assert.match(INDEX_SRC, /case "escalate_story":\s*\n\s*return await escalateStory\(args\);/);
    assert.ok(README.includes("`escalate_story`"));
  });

  test("the description says what it is FOR and that it is one-way", () => {
    // The tool is chosen by its description, and the two things a session gets wrong are
    // reaching for it on an ordinary blocker and carrying on working after it succeeds.
    const start = INDEX_SRC.indexOf('name: "escalate_story",');
    const decl = INDEX_SRC.slice(start, INDEX_SRC.indexOf("\n  },\n  {", start));
    assert.match(decl, /contradicts/);
    assert.match(decl, /not for an ordinary blocker|NOT use it for an ordinary blocker/);
    assert.match(decl, /ONE-WAY|one-way/);
  });

  test("the handler injects the real apiCall and leads with the stop notice", () => {
    const source = functionSource("escalateStory");
    assert.match(source, /escalateStoryRequest\(args, \{ apiCall \}\)/);
    assert.match(source, /escalationNotice\(result\)/);
    assert.match(source, /\{ type: "text", text: notice \}, \.\.\.toContent\(result\)\.content/);
  });
});
