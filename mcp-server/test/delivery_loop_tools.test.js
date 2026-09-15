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
    // or a deliberate branch. `kind` is NOT one of them — see the enum test below.
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

    assert.equal(calls[0].body.kind, "implement");
    assert.equal(calls[0].body.repo, "mkreyman/home_care_billing");
    assert.equal(calls[0].body.branch, "feature/x");
    assert.equal(calls[0].body.base_branch, "main");
    assert.equal(calls[0].body.wall_clock_seconds, 900);
    assert.equal(calls[0].body.max_turns, 30);
  });

  test("`kind` is declared `implement` and nothing else", () => {
    // This test used to pass `kind: "triage"` and assert it was forwarded, on a comment
    // saying triage became dispatchable in contract 1.10.0. It did — from
    // `Loopctl.Delivery.TriageDispatcher`, against stories at `detected`, claiming nothing.
    // PLACEMENT claims the story, which is what mints the custody lineage, so 2.96.0 narrowed
    // this tool's enum to `implement` alone. The old test pinned the opposite of the shipped
    // contract.
    //
    // Source-pinned on the DECLARATION rather than on the call, because the enum is the only
    // thing that refuses a caller: `placeDispatch` forwards whatever `kind` it is handed, and
    // the MCP client is what validates against the schema. Widening the enum without coming
    // back here turns this red.
    const start = INDEX_SRC.indexOf('name: "place_dispatch"');
    assert.ok(start > -1, "place_dispatch is not declared");

    const end = INDEX_SRC.indexOf('name: "', start + 1);
    assert.ok(end > start, "place_dispatch has no following declaration to bound it");

    const declaration = INDEX_SRC.slice(start, end);
    const declared = declaration.match(/kind: \{[\s\S]*?enum: (\[[^\]]*\])/);

    assert.ok(declared, "place_dispatch declares no `kind` enum");
    assert.equal(declared[1], '["implement"]');
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

describe("id validation — shared by every verb here", () => {
  // NOT because the server 500s on a malformed id; it does not. `Ecto.Query.CastError` has a
  // deliberate `Plug.Exception` impl returning 404 (`cast_error_handler.ex:26-29`, pinned by
  // `cast_error_handler_test.exs:9-12`), and the body is the generic
  // `{"error": {"status": 404, "message": "Not found"}}`. The problem is that this is the
  // IDENTICAL answer a well-formed id naming no story gets (`fallback_controller.ex:74-78`),
  // and the two have opposite remedies. Checking the SHAPE client-side tells them apart, and
  // costs no round trip. See the block comment over `uuid()` in lib/delivery-loop.js.
  const MALFORMED = "not-a-uuid";

  test("refuses a malformed story_id on every verb that takes one, before any call", async () => {
    const checks = [
      ["place_dispatch", (api) => placeDispatch({ story_id: MALFORMED, runner_id: RUNNER_ID }, deps({ apiCall: api }))],
      ["story_stage", (api) => storyStage({ story_id: MALFORMED }, { apiCall: api })],
      ["resolve_escalation", (api) => resolveEscalation({ story_id: MALFORMED, to: "queued" }, deps({ apiCall: api }))],
      ["force_unclaim_story", (api) => forceUnclaimStory({ story_id: MALFORMED }, { orchKey: "orch-key", apiCall: api })],
    ];

    for (const [name, run] of checks) {
      const { calls, apiCall } = fakeApi();
      const result = await run(apiCall);

      assert.equal(result.error, true, `${name} accepted a malformed story_id`);
      assert.match(result.body, /must be a UUID/, `${name} did not name the shape`);
      assert.equal(calls.length, 0, `${name} sent a request anyway`);
    }
  });

  test("refuses a malformed runner_id too", async () => {
    const { calls, apiCall } = fakeApi();

    const result = await placeDispatch(
      { story_id: STORY_ID, runner_id: MALFORMED },
      deps({ apiCall }),
    );

    assert.equal(result.error, true);
    assert.match(result.body, /runner_id/);
    assert.match(result.body, /must be a UUID/);
    assert.equal(calls.length, 0);
  });

  test("names the SHAPE and never echoes the value back", async () => {
    // A malformed id is frequently something pasted into the wrong argument — a token, a
    // path, a whole line — and a tool result lands in the transcript. So the refusal says what
    // was expected and how long the thing was, and repeats none of it.
    const secretish = "lc_live_0123456789abcdefghijklmnop";
    const { apiCall } = fakeApi();

    const result = await forceUnclaimStory(
      { story_id: secretish },
      { orchKey: "orch-key", apiCall },
    );

    assert.equal(result.error, true);
    assert.ok(!result.body.includes(secretish), "the refusal echoed the value");
    assert.match(result.body, new RegExp(`${secretish.length}-character`));
  });

  test("a well-formed UUID still passes, in either case", async () => {
    // The guard must not refuse what the server accepts: Ecto casts an upper-case UUID.
    const { calls, apiCall } = fakeApi();

    await forceUnclaimStory(
      { story_id: STORY_ID.toUpperCase() },
      { orchKey: "orch-key", apiCall },
    );

    assert.equal(calls.length, 1);
    assert.equal(calls[0].path, `/api/v1/stories/${STORY_ID.toUpperCase()}/force-unclaim`);
  });

  test("a missing id is still `required`, not `malformed`", async () => {
    const { apiCall } = fakeApi();
    const result = await storyStage({}, { apiCall });

    assert.match(result.body, /is required/);
  });

  test("a local refusal carries status 0, never the 404 the server would have sent", async () => {
    // The shape decision this guard forces, pinned so it cannot drift back. `status: 0` is
    // this client's marker for "no request was sent" — `apiCall`'s missing-key, network-error
    // and timeout branches all use it. Stamping the refusal 404 instead would make it
    // indistinguishable from the server's own answer for a malformed id
    // (`cast_error_handler.ex:26-29`), which is the ambiguity the check exists to REMOVE.
    const { calls, apiCall } = fakeApi();

    const result = await forceUnclaimStory(
      { story_id: "not-a-uuid" },
      { orchKey: "orch-key", apiCall },
    );

    assert.equal(result.status, 0, "a local refusal must not claim a server answered");
    assert.equal(calls.length, 0);
  });
});

describe("the wiring in index.js", () => {
  test("every delivery-loop tool is declared, dispatched TO ITS OWN HANDLER, and documented", () => {
    // The defect these tools exist for is a verb that exists and nothing calls. A tool
    // declared and not dispatched, or dispatched and not declared, is that same defect inside
    // the MCP server, and it is invisible until someone tries to use it.
    //
    // THE CASE LABEL ALONE IS NOT THE WIRING, and the first version of this test asserted only
    // that. Pointing `case "force_unclaim_story":` at `resolveEscalation(args)` left the whole
    // suite green — the label was still there, so the grep still matched, while the tool called
    // a different endpoint with a different key. So the HANDLER IDENTIFIER is asserted too,
    // which is the thing that actually decides what the call does.
    //
    // Same for the README: a bare `includes(name)` matched the name anywhere in the file, and
    // every one of these is named in surrounding prose, so a tool could lose its row and the
    // test would not notice. The row is what an operator reads, so the row is what is pinned.
    const wiring = {
      place_dispatch: "placeDispatch",
      story_stage: "storyStage",
      resolve_escalation: "resolveEscalation",
      force_unclaim_story: "forceUnclaimStory",
    };

    for (const [name, handler] of Object.entries(wiring)) {
      assert.ok(INDEX_SRC.includes(`name: "${name}"`), `${name} is not declared`);
      assert.match(
        INDEX_SRC,
        new RegExp(`case "${name}":\\s*return await ${handler}\\(`),
        `${name} is not dispatched to ${handler}()`,
      );
      assert.ok(
        README.split("\n").some((line) => line.startsWith("| `" + name + "` |")),
        `${name} has no row in a README tool table`,
      );
    }
  });

  test("force_unclaim_story selects its key the way every exact_role verb does", () => {
    // The endpoint is `exact_role: :orchestrator` (`story_verification_controller.ex:29-30`),
    // so it needs an orchestrator-ROLE key; which env var holds one is a separate question
    // and `lib/custody-key.js` answers it — LOOPCTL_ORCH_KEY sent exactly when set, a global
    // LOOPCTL_API_KEY otherwise. What this pins is that the handler does not answer it itself.
    // The behaviour of that selection, including the orchestrator-only-global config, is
    // tested in test/custody_key_pinning.test.js.
    const start = INDEX_SRC.indexOf("async function forceUnclaimStory(");
    assert.ok(start > -1, "the force_unclaim_story handler was not found");

    // Bounded by the NEXT function rather than a named neighbour, so inserting something
    // between them cannot silently widen what this reads.
    const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
    assert.ok(end > start, "the handler has no following function to bound it");

    // COMMENTS STRIPPED FIRST. The handler carries a comment explaining the selection, and
    // that comment names the same identifiers — so the raw slice is satisfied by a site where
    // the wiring has been commented OUT, which is the shape a disabling edit takes. Verified
    // by mutation: without this, replacing the wiring with a block comment left the suite
    // green.
    const handler = INDEX_SRC.slice(start, end)
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/\/\/[^\n]*/g, "");

    assert.match(
      handler,
      /orchestratorKeyArgs\(\)/,
      "it does not call orchestratorKeyArgs, so its key selection is its own",
    );
    assert.ok(
      handler.includes("orch.override") && handler.includes("orch.options"),
      "it drops what orchestratorKeyArgs chose, so LOOPCTL_ORCH_KEY is no longer sent exactly",
    );
    assert.ok(
      handler.includes("orchKey: orch.resolved"),
      "its local refusal does not branch on the key that will actually be sent",
    );
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
