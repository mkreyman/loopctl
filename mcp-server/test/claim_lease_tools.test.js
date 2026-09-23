/**
 * #803/#810 on the MCP side: renew_story_claim, and claim_story surfacing the claim lease.
 *
 * Runs the real code in ../lib/claim-lease.js with `apiCall` injected as a recording fake;
 * the last block source-pins index.js so the wiring cannot drift from the logic.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { renewStoryClaim, renewClaimPath, claimLeaseNotice } from "../lib/claim-lease.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const STORY_ID = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const ENV = {
  LOOPCTL_AGENT_KEY: "agent-key",
  LOOPCTL_ORCH_KEY: "orch-key",
  LOOPCTL_USER_KEY: "user-key",
};

function fakeApi(response = { story: { id: STORY_ID } }) {
  const calls = [];
  const apiCall = async (method, apiPath, body, key) => {
    calls.push({ method, path: apiPath, body, key });
    return response;
  };
  return { calls, apiCall };
}

describe("renew_story_claim", () => {
  test("POSTs the claim_epoch to /stories/:id/renew-claim on the AGENT key", async () => {
    const { calls, apiCall } = fakeApi();
    await renewStoryClaim({ story_id: STORY_ID, claim_epoch: 7 }, { apiCall, env: ENV });

    assert.deepEqual(calls, [
      {
        method: "POST",
        path: `/api/v1/stories/${STORY_ID}/renew-claim`,
        body: { claim_epoch: 7 },
        key: "agent-key",
      },
    ]);
  });

  test("reads LOOPCTL_AGENT_KEY from process.env when no env is injected (the index.js path)", async () => {
    const saved = process.env.LOOPCTL_AGENT_KEY;
    process.env.LOOPCTL_AGENT_KEY = "process-agent-key";
    try {
      const { calls, apiCall } = fakeApi();
      await renewStoryClaim({ story_id: STORY_ID, claim_epoch: 1 }, { apiCall });
      assert.equal(calls[0].key, "process-agent-key");
    } finally {
      if (saved === undefined) delete process.env.LOOPCTL_AGENT_KEY;
      else process.env.LOOPCTL_AGENT_KEY = saved;
    }
  });

  test("forwards epoch 0 and a malformed epoch unchanged, for the server to judge", async () => {
    const { calls, apiCall } = fakeApi();
    await renewStoryClaim({ story_id: STORY_ID, claim_epoch: 0 }, { apiCall, env: ENV });
    await renewStoryClaim({ story_id: STORY_ID, claim_epoch: "3" }, { apiCall, env: ENV });
    assert.deepEqual(calls.map((c) => c.body), [{ claim_epoch: 0 }, { claim_epoch: "3" }]);
  });

  for (const [status, code] of [
    [400, "bad_request"],
    [422, "not_claimed"],
    [409, "stale_claim_epoch"],
    [409, "not_claimant"],
  ]) {
    test(`passes a ${status} ${code} through unchanged`, async () => {
      const failure = { error: true, status, body: { error: { status, code, message: "no" } } };
      const { apiCall } = fakeApi(failure);
      const result = await renewStoryClaim(
        { story_id: STORY_ID, claim_epoch: 2 },
        { apiCall, env: ENV },
      );
      assert.deepEqual(result, failure);
    });
  }

  test("requires story_id and calls nothing without it", async () => {
    const { calls, apiCall } = fakeApi();
    const result = await renewStoryClaim({ claim_epoch: 1 }, { apiCall, env: ENV });
    assert.equal(result.error, true);
    assert.deepEqual(calls, []);
  });

  test("encodes the story id into the path", () => {
    assert.equal(renewClaimPath("a/b"), "/api/v1/stories/a%2Fb/renew-claim");
  });
});

describe("claimLeaseNotice", () => {
  test("names the epoch and the deadline when the server returns them", () => {
    const notice = claimLeaseNotice({
      story: { id: STORY_ID, claim_epoch: 4, claimed_until: "2026-09-13T10:00:00Z" },
    });
    assert.match(notice, /claim_epoch 4/);
    assert.match(notice, /claimed_until 2026-09-13T10:00:00Z/);
    assert.match(notice, /renew_story_claim/);
  });

  test("says there is no lease when claimed_until is null", () => {
    assert.match(claimLeaseNotice({ story: { claim_epoch: 0, claimed_until: null } }), /no lease/);
  });

  test("is null on an older server that returns neither, and on an error", () => {
    assert.equal(claimLeaseNotice({ story: { id: STORY_ID, status: "assigned" } }), null);
    assert.equal(claimLeaseNotice({ error: true, status: 409, body: {} }), null);
    assert.equal(claimLeaseNotice(undefined), null);
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

  test("renew_story_claim is declared with a required integer claim_epoch, dispatched, and documented", () => {
    const start = INDEX_SRC.indexOf('name: "renew_story_claim",');
    assert.notEqual(start, -1);
    const decl = INDEX_SRC.slice(start, INDEX_SRC.indexOf("\n  },\n  {", start));
    assert.match(decl, /claim_epoch: \{\s*type: "integer"/);
    assert.match(decl, /required: \["story_id", "claim_epoch"\]/);
    assert.match(INDEX_SRC, /case "renew_story_claim":\s*\n\s*return await renewStoryClaim\(args\);/);
    assert.ok(README.includes("`renew_story_claim`"));
  });

  test("the handler injects the real apiCall and surfaces the lease", () => {
    assert.match(
      functionSource("renewStoryClaim"),
      /withClaimLeaseNotice\(await renewStoryClaimRequest\(args, \{ apiCall \}\)\)/,
    );
  });

  test("claim_story's description names the story_escalated refusal and its remedy", () => {
    const decl = INDEX_SRC.slice(INDEX_SRC.indexOf('name: "claim_story"'));
    const description = decl.slice(0, decl.indexOf("inputSchema"));
    assert.match(description, /409 story_escalated/);
    assert.match(description, /resolve_escalation/);
    assert.match(README, /\| `claim_story` \|[^\n]*409 `story_escalated`/);
  });

  test("claim_story surfaces the lease notice ahead of the JSON", () => {
    assert.match(functionSource("claimStory"), /return withClaimLeaseNotice\(result\);/);
    const wrap = functionSource("withClaimLeaseNotice");
    assert.match(wrap, /claimLeaseNotice\(result\)/);
    assert.match(wrap, /\{ type: "text", text: notice \}, \.\.\.toContent\(result\)\.content/);
  });
});
