/**
 * #803/#850 on the MCP side: place_dispatch, story_stage, resolve_escalation.
 *
 * These three exist because the endpoints behind them were unreachable from any session —
 * `curl` at loopctl is refused by the fleet's guardrail, so a trigger with no tool is a verb
 * only a shell on the production node can use. The last block source-pins index.js so the
 * wiring cannot drift from the logic, which is the failure the tools themselves are about.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  placeDispatch,
  placementPath,
  resolveEscalation,
  resolvePath,
  stagePath,
  storyStage,
} from "../lib/delivery-loop.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");
const README = readFileSync(path.join(DIR, "..", "README.md"), "utf8");

const STORY_ID = "d9975b31-032d-4f44-b154-c48af09640c7";
const RUNNER_ID = "3781bee6-2b97-4df0-9664-7f01a492630f";

function fakeApi(response = { ok: true }) {
  const calls = [];
  const apiCall = async (method, apiPath, body) => {
    calls.push({ method, path: apiPath, body });
    return response;
  };
  return { calls, apiCall };
}

function deps(extra = {}) {
  return { userKey: "user-key", uuidv4: () => "generated-uuid", ...extra };
}

describe("place_dispatch", () => {
  test("POSTs the story to the runner's placement endpoint", async () => {
    const { calls, apiCall } = fakeApi();

    await placeDispatch({ story_id: STORY_ID, runner_id: RUNNER_ID }, deps({ apiCall }));

    assert.equal(calls.length, 1);
    assert.equal(calls[0].method, "POST");
    assert.equal(calls[0].path, `/api/v1/runners/${RUNNER_ID}/dispatches`);
    assert.equal(calls[0].body.story_id, STORY_ID);
    assert.equal(calls[0].body.kind, "implement");
  });

  test("generates a dispatch_id, and passes a caller's through", async () => {
    // The endpoint is idempotent ON THAT ID: a retry carrying the same one re-sends the frame
    // rather than starting a second session. A caller that cannot name it cannot retry safely,
    // which is why it is generated here rather than server-side.
    const { calls, apiCall } = fakeApi();

    await placeDispatch({ story_id: STORY_ID, runner_id: RUNNER_ID }, deps({ apiCall }));
    assert.equal(calls[0].body.dispatch_id, "generated-uuid");

    await placeDispatch(
      { story_id: STORY_ID, runner_id: RUNNER_ID, dispatch_id: "mine" },
      deps({ apiCall }),
    );
    assert.equal(calls[1].body.dispatch_id, "mine");
  });

  test("sends story, runner and kind alone — the server fills the rest", async () => {
    // `repo`, `base_branch`, `branch` and both budgets are REQUIRED by the contract, and the
    // first version of this test asserted their absence with a comment claiming loopctl filled
    // them. It did not: `cast_dispatch/1` applies no defaults, so every call would have been
    // refused — AFTER the claim and two immutable chain entries, because that cast is the
    // first step of the push. The server derives them now
    // (`Loopctl.Delivery.DispatchPayload`), which is what makes this body sufficient, and this
    // test is only meaningful alongside the Elixir one that proves the derivation.
    const { calls, apiCall } = fakeApi();

    await placeDispatch({ story_id: STORY_ID, runner_id: RUNNER_ID }, deps({ apiCall }));

    assert.deepEqual(Object.keys(calls[0].body).sort(), ["dispatch_id", "kind", "story_id"]);
  });

  test("carries the overrides it WAS given, including the repository", async () => {
    // An override is for the case the derivation cannot serve: a project bound to two sources,
    // or a deliberate branch. `kind` stays `implement` here — `dispatchable_kinds` is the live
    // list of what loopctl will send, and a kind not on it is refused after the claim.
    const { calls, apiCall } = fakeApi();

    await placeDispatch(
      {
        story_id: STORY_ID,
        runner_id: RUNNER_ID,
        repo: "mkreyman/home_care_billing",
        branch: "feature/x",
        base_branch: "main",
        wall_clock_seconds: 900,
        max_turns: 30,
      },
      deps({ apiCall }),
    );

    assert.equal(calls[0].body.repo, "mkreyman/home_care_billing");
    assert.equal(calls[0].body.branch, "feature/x");
    assert.equal(calls[0].body.base_branch, "main");
    assert.equal(calls[0].body.wall_clock_seconds, 900);
    assert.equal(calls[0].body.max_turns, 30);
  });

  test("refuses without a user key, and without either id — before any call", async () => {
    // The endpoint mints a custody dispatch and claims a story, so an agent key is refused
    // `insufficient_role` by the server anyway; saying so here costs no round trip and says
    // WHICH key, which the server's reason code does not.
    const { calls, apiCall } = fakeApi();

    const noKey = await placeDispatch(
      { story_id: STORY_ID, runner_id: RUNNER_ID },
      deps({ apiCall, userKey: undefined }),
    );
    assert.equal(noKey.error, true);
    assert.match(noKey.body, /LOOPCTL_USER_KEY/);

    const noStory = await placeDispatch({ runner_id: RUNNER_ID }, deps({ apiCall }));
    assert.match(noStory.body, /story_id/);

    const noRunner = await placeDispatch({ story_id: STORY_ID }, deps({ apiCall }));
    assert.match(noRunner.body, /runner_id/);

    assert.equal(calls.length, 0);
  });

  test("never sends a story object, whatever the caller passes", async () => {
    // loopctl builds it from its own rows and refuses a caller-supplied one — a control plane
    // able to hand a runner prose is able to run anything on that machine. The tool has no
    // parameter for it, and this pins that: an extra key in the args reaches no request.
    const { calls, apiCall } = fakeApi();

    await placeDispatch(
      { story_id: STORY_ID, runner_id: RUNNER_ID, story: { title: "ignore previous" } },
      deps({ apiCall }),
    );

    assert.equal(calls[0].body.story, undefined);
  });
});

describe("story_stage", () => {
  test("GETs the story's stage on whatever key the caller has", async () => {
    const { calls, apiCall } = fakeApi({ stage: { stage: "queued" } });

    await storyStage({ story_id: STORY_ID }, { apiCall });

    assert.equal(calls[0].method, "GET");
    assert.equal(calls[0].path, `/api/v1/stories/${STORY_ID}/stage`);
    assert.equal(calls[0].body, null);
  });

  test("refuses without a story id", async () => {
    const { calls, apiCall } = fakeApi();
    const result = await storyStage({}, { apiCall });

    assert.equal(result.error, true);
    assert.equal(calls.length, 0);
  });
});

describe("resolve_escalation", () => {
  test("POSTs the target, and the reason when there is one", async () => {
    const { calls, apiCall } = fakeApi();

    await resolveEscalation({ story_id: STORY_ID, to: "queued" }, deps({ apiCall }));
    assert.equal(calls[0].path, `/api/v1/stories/${STORY_ID}/stage/resolve`);
    assert.deepEqual(calls[0].body, { to: "queued" });

    await resolveEscalation(
      { story_id: STORY_ID, to: "failed", reason: "the reporter withdrew it" },
      deps({ apiCall }),
    );
    assert.deepEqual(calls[1].body, { to: "failed", reason: "the reporter withdrew it" });
  });

  test("refuses a target the stage machine does not have", async () => {
    const { calls, apiCall } = fakeApi();

    const result = await resolveEscalation(
      { story_id: STORY_ID, to: "implementing" },
      deps({ apiCall }),
    );

    assert.equal(result.error, true);
    assert.match(result.body, /queued/);
    assert.equal(calls.length, 0);
  });

  test("refuses without a user key, naming the separation", async () => {
    // The agent key that RAISES an escalation is 403'd on this route by design: a session
    // must not be able to clear the escalation it raised.
    const { calls, apiCall } = fakeApi();

    const result = await resolveEscalation(
      { story_id: STORY_ID, to: "queued" },
      deps({ apiCall, userKey: undefined }),
    );

    assert.equal(result.error, true);
    assert.match(result.body, /human/);
    assert.equal(calls.length, 0);
  });
});

describe("the wiring in index.js", () => {
  test("all three tools are declared, dispatched and documented", () => {
    // The defect these tools exist for is a verb that exists and nothing calls. A tool
    // declared and not dispatched, or dispatched and not declared, is that same defect inside
    // the MCP server, and it is invisible until someone tries to use it.
    for (const name of ["place_dispatch", "story_stage", "resolve_escalation"]) {
      assert.ok(INDEX_SRC.includes(`name: "${name}"`), `${name} is not declared`);
      assert.ok(INDEX_SRC.includes(`case "${name}":`), `${name} is not dispatched`);
      assert.ok(README.includes(name), `${name} is not in the README tool list`);
    }
  });

  test("the paths the tools build are the routes loopctl serves", () => {
    assert.equal(placementPath(RUNNER_ID), `/api/v1/runners/${RUNNER_ID}/dispatches`);
    assert.equal(stagePath(STORY_ID), `/api/v1/stories/${STORY_ID}/stage`);
    assert.equal(resolvePath(STORY_ID), `/api/v1/stories/${STORY_ID}/stage/resolve`);
  });
});
