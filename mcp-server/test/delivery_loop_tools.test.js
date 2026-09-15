/**
 * #803/#850/#846 on the MCP side: place_dispatch, story_stage, resolve_escalation,
 * force_unclaim_story.
 *
 * These exist because the endpoints behind them were unreachable from any session —
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
  forceUnclaimPath,
  forceUnclaimStory,
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
    // or a deliberate branch. `triage` is dispatchable since contract 1.10.0 — and reaches
    // only a runner that DECLARES the kind on join.
    const { calls, apiCall } = fakeApi();

    await placeDispatch(
      {
        story_id: STORY_ID,
        runner_id: RUNNER_ID,
        kind: "triage",
        repo: "mkreyman/home_care_billing",
        branch: "feature/x",
        base_branch: "main",
        wall_clock_seconds: 900,
        max_turns: 30,
      },
      deps({ apiCall }),
    );

    assert.equal(calls[0].body.kind, "triage");
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

describe("force_unclaim_story", () => {
  test("POSTs to the hyphenated force-unclaim route with no body", async () => {
    // The route is `force-unclaim`. An underscore there is a 404 that reads like the story
    // not existing, and the endpoint takes no body — the story is named in the path.
    const { calls, apiCall } = fakeApi({ story: { agent_status: "pending" } });

    await forceUnclaimStory({ story_id: STORY_ID }, { orchKey: "orch-key", apiCall });

    assert.equal(calls.length, 1);
    assert.equal(calls[0].method, "POST");
    assert.equal(calls[0].path, `/api/v1/stories/${STORY_ID}/force-unclaim`);
    assert.equal(calls[0].body, null);
  });

  test("refuses without the ORCH key, naming the gate a bigger key cannot pass", async () => {
    // `exact_role: :orchestrator` is a chain-of-custody gate: a user or superadmin key is
    // 403'd there like any other non-member. Saying WHICH key costs no round trip, and the
    // server's reason code does not say it.
    const { calls, apiCall } = fakeApi();

    const result = await forceUnclaimStory(
      { story_id: STORY_ID },
      { orchKey: undefined, apiCall },
    );

    assert.equal(result.error, true);
    assert.match(result.body, /LOOPCTL_ORCH_KEY/);
    assert.match(result.body, /exact_role/);
    assert.equal(calls.length, 0);
  });

  test("refuses without a story id, before any call", async () => {
    const { calls, apiCall } = fakeApi();

    const result = await forceUnclaimStory({}, { orchKey: "orch-key", apiCall });

    assert.equal(result.error, true);
    assert.match(result.body, /story_id/);
    assert.equal(calls.length, 0);
  });
});

describe("the wiring in index.js", () => {
  test("every delivery-loop tool is declared, dispatched and documented", () => {
    // The defect these tools exist for is a verb that exists and nothing calls. A tool
    // declared and not dispatched, or dispatched and not declared, is that same defect inside
    // the MCP server, and it is invisible until someone tries to use it.
    for (const name of [
      "place_dispatch",
      "story_stage",
      "resolve_escalation",
      "force_unclaim_story",
    ]) {
      assert.ok(INDEX_SRC.includes(`name: "${name}"`), `${name} is not declared`);
      assert.ok(INDEX_SRC.includes(`case "${name}":`), `${name} is not dispatched`);
      assert.ok(README.includes(name), `${name} is not in the README tool list`);
    }
  });

  test("force_unclaim_story is pinned to the ORCH key, exactly", () => {
    // `resolveKey` prefers a global LOOPCTL_API_KEY, and a global key of ANY other role —
    // user and superadmin included — is 403'd by an `exact_role: :orchestrator` gate. Reading
    // the env var is not enough on its own: without `exactKey` the request would still go out
    // under whatever LOOPCTL_API_KEY holds, and the 403 would read as the story being
    // unfreeable rather than the key being the wrong one.
    const start = INDEX_SRC.indexOf("async function forceUnclaimStory(");
    assert.ok(start > -1, "the force_unclaim_story handler was not found");

    // Bounded by the NEXT function rather than a named neighbour, so inserting something
    // between them cannot silently widen what this reads.
    const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
    assert.ok(end > start, "the handler has no following function to bound it");

    const handler = INDEX_SRC.slice(start, end);
    assert.ok(handler.includes("LOOPCTL_ORCH_KEY"), "it does not read LOOPCTL_ORCH_KEY");
    assert.ok(handler.includes("exactKey: true"), "it does not pin the key exactly");
    assert.ok(
      !handler.includes("LOOPCTL_USER_KEY"),
      "it reaches for the user key, which that gate refuses",
    );
  });

  test("the paths the tools build are the routes loopctl serves", () => {
    assert.equal(placementPath(RUNNER_ID), `/api/v1/runners/${RUNNER_ID}/dispatches`);
    assert.equal(stagePath(STORY_ID), `/api/v1/stories/${STORY_ID}/stage`);
    assert.equal(resolvePath(STORY_ID), `/api/v1/stories/${STORY_ID}/stage/resolve`);
    assert.equal(forceUnclaimPath(STORY_ID), `/api/v1/stories/${STORY_ID}/force-unclaim`);
  });
});
