/**
 * `update_story` — correcting a filed story (loopctl #846.6).
 *
 * The endpoint (`PATCH /api/v1/stories/:id`, `lib/loopctl_web/router.ex:477`) has been served
 * since long before this package's write surface was built and no tool reached it, so a
 * session that filed a story and then found its own severity wrong could not correct it.
 *
 * What these tests hold is the shape of what is SENT — the server's own guards are tested in
 * the Elixir suite, and repeating them here would only pin this client's guess at them. The
 * two local refusals below exist because the server's answer in those cases is a 200 that
 * changed nothing, which a caller cannot tell from success.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import { storyPath, updateBody, updateStory } from "../lib/story-update.js";
import { PKG_DIR, loadTools } from "./tool-surface.js";

const INDEX_SRC = readFileSync(path.join(PKG_DIR, "index.js"), "utf8");
const README = readFileSync(path.join(PKG_DIR, "README.md"), "utf8");

const STORY_ID = "a31e68c6-8694-45d0-866d-178418e04eec";

function fakeApi(response = { story: {} }) {
  const calls = [];
  return {
    calls,
    apiCall: async (method, apiPath, body) => {
      calls.push({ method, path: apiPath, body });
      return response;
    },
  };
}

describe("update_story sends what it was given, and nothing else", () => {
  test("PATCHes the story, carrying only the named fields", async () => {
    const { calls, apiCall } = fakeApi();

    await updateStory({ story_id: STORY_ID, title: "corrected" }, { apiCall });

    assert.equal(calls.length, 1);
    assert.equal(calls[0].method, "PATCH");
    assert.equal(calls[0].path, `/api/v1/stories/${STORY_ID}`);
    assert.deepEqual(calls[0].body, { title: "corrected" });
  });

  test("carries all five updatable fields when all five are named", async () => {
    const { calls, apiCall } = fakeApi();

    await updateStory(
      {
        story_id: STORY_ID,
        title: "t",
        description: "d",
        acceptance_criteria: [{ id: "AC-1", description: "x" }],
        estimated_hours: 3,
        metadata: { severity: "high" },
      },
      { apiCall },
    );

    assert.deepEqual(Object.keys(calls[0].body).sort(), [
      "acceptance_criteria",
      "description",
      "estimated_hours",
      "metadata",
      "title",
    ]);
  });

  test("drops a field the endpoint cannot cast, rather than sending it", async () => {
    // `StoryController.update/2` reads exactly five params (`story_controller.ex:434-440`)
    // and `Story.update_changeset/2` casts exactly those five (`story.ex:189-195`). Anything
    // else — a status, the story number, an agent id — is ignored server-side, so sending it
    // makes a request look like it did something it did not.
    const { calls, apiCall } = fakeApi();

    await updateStory(
      { story_id: STORY_ID, title: "t", number: "846.1", agent_status: "verified" },
      { apiCall },
    );

    assert.deepEqual(calls[0].body, { title: "t" });
  });
});

describe("the refusals, each for an answer the server cannot distinguish from success", () => {
  test("refuses a request naming no updatable field, before any call", async () => {
    // `Stories.update_story/4` logs `action: "updated"` unconditionally
    // (`lib/loopctl/work_breakdown/stories.ex:213-249`), so an empty PATCH is a 200 plus an
    // audit entry for a change that never happened.
    const { calls, apiCall } = fakeApi();

    const result = await updateStory({ story_id: STORY_ID }, { apiCall });

    assert.equal(result.error, true);
    assert.equal(result.status, 0, "a local refusal must not claim a server answered");
    assert.match(result.body, /Nothing to update/);
    assert.equal(calls.length, 0);
  });

  test("refuses null, which the controller would silently drop", async () => {
    // `Map.reject(attrs, fn {_k, v} -> is_nil(v) end)` (`story_controller.ex:443`) removes it
    // before the changeset, so `description: null` is a no-op answering 200 — not an erase.
    const { calls, apiCall } = fakeApi();

    const result = await updateStory({ story_id: STORY_ID, description: null }, { apiCall });

    assert.equal(result.error, true);
    assert.match(result.body, /cannot be set to null/);
    assert.equal(calls.length, 0);
  });

  test("refuses an estimated_hours no decimal parser accepts", async () => {
    // `parse_decimal/1` (`story_controller.ex:530-538`) answers nil for a string
    // `Decimal.parse/1` rejects, and that nil is then dropped by the same `Map.reject` — so
    // the request answers 200 with the old estimate.
    const { calls, apiCall } = fakeApi();

    const bad = await updateStory({ story_id: STORY_ID, estimated_hours: "five" }, { apiCall });
    assert.equal(bad.error, true);
    assert.match(bad.body, /estimated_hours/);
    assert.equal(calls.length, 0);

    // A numeric STRING is what the server itself accepts, so it must not be refused here.
    await updateStory({ story_id: STORY_ID, estimated_hours: "5.5" }, { apiCall });
    assert.equal(calls[0].body.estimated_hours, "5.5");
  });

  test("refuses a metadata that is not an object", async () => {
    const { calls, apiCall } = fakeApi();

    for (const value of [["a"], "a", 3, true]) {
      const result = await updateStory({ story_id: STORY_ID, metadata: value }, { apiCall });
      assert.equal(result.error, true, `metadata ${JSON.stringify(value)} was accepted`);
    }

    assert.equal(calls.length, 0);
  });

  test("refuses a missing story id", async () => {
    const { calls, apiCall } = fakeApi();

    const result = await updateStory({ title: "t" }, { apiCall });

    assert.equal(result.error, true);
    assert.match(result.body, /story_id/);
    assert.equal(calls.length, 0);
  });
});

describe("updateBody", () => {
  test("omits what was not named and keeps a falsy value that WAS", async () => {
    // `undefined` is "not named"; `""` and `0` are values a caller chose and must survive.
    assert.deepEqual(updateBody({ story_id: STORY_ID, title: "" }).body, { title: "" });
    assert.deepEqual(updateBody({ story_id: STORY_ID, estimated_hours: 0 }).body, {
      estimated_hours: 0,
    });
    assert.deepEqual(updateBody({ story_id: STORY_ID }).body, {});
  });

  test("builds the path with the id encoded", () => {
    assert.equal(storyPath(STORY_ID), `/api/v1/stories/${STORY_ID}`);
    assert.equal(storyPath("a/b"), "/api/v1/stories/a%2Fb");
  });
});

describe("the hazard the description has to carry", () => {
  // `metadata` is an ordinary `:map` field (`lib/loopctl/work_breakdown/story.ex:84`) in
  // `update_changeset/2`'s cast list (`:189-195`), so the map sent REPLACES the stored one —
  // there is no merge on this path. That is the laundering hazard loopctl's CLAUDE.md
  // documents: `lifecycle_entered_at` lived in metadata and one ordinary PATCH erased it,
  // restoring the claim -> force-unclaim -> backfill-to-verified launder. It is a COLUMN now
  // (`story.ex:102`) that neither changeset casts (`story.ex:95-101`).
  //
  // An operator reads the tool description, not this file, so the description is what is
  // pinned. Both halves: that metadata is replaced whole, and that the column is the reason
  // this endpoint can no longer reach that particular marker.
  const tool = loadTools().find((t) => t.name === "update_story");

  test("update_story is declared", () => {
    assert.ok(tool, "update_story is not declared");
  });

  test("its description says metadata is REPLACED, not merged", () => {
    assert.match(tool.description, /REPLACES THE WHOLE MAP/);
    assert.match(tool.description, /SILENTLY DROPS/);
    assert.match(
      tool.description,
      /READ THE STORY FIRST/,
      "it does not tell the caller how to avoid the erasure",
    );
  });

  test("its description names lifecycle_entered_at and why it is a column", () => {
    assert.match(tool.description, /lifecycle_entered_at/);
    assert.match(tool.description, /COLUMN/);
    assert.match(
      tool.description,
      /backfilled straight to `verified`/,
      "it states the erasure without stating what the erasure BUYS an attacker",
    );
  });

  test("its metadata property repeats the warning where a caller filling it will see it", () => {
    assert.match(tool.inputSchema.properties.metadata.description, /REPLACES the whole metadata/);
  });
});

describe("the wiring in index.js", () => {
  test("update_story is declared, dispatched to its own handler, and documented", () => {
    // The same three-part pin `delivery_loop_tools.test.js` uses, for the same reason: a tool
    // declared and not dispatched, or dispatched and not declared, is invisible until someone
    // tries to use it — which is the whole defect this tool exists for.
    assert.ok(INDEX_SRC.includes('name: "update_story"'), "update_story is not declared");
    assert.match(
      INDEX_SRC,
      /case "update_story":\s*return await updateStory\(/,
      "update_story is not dispatched to updateStory()",
    );
    assert.ok(
      README.split("\n").some((line) => line.startsWith("| `update_story` |")),
      "update_story has no row in a README tool table",
    );
  });

  test("its handler sends the ORCH key WITHOUT pinning it", () => {
    // `role: :orchestrator` (`story_controller.ex:29-30`) is the HIERARCHY form, not
    // `exact_role:`, so a `:user` or `:superadmin` key passes the gate too. Pinning the key
    // with `exactKey` — the way the custody verbs must — would refuse a global
    // LOOPCTL_API_KEY that this endpoint accepts. Comments stripped first: the handler
    // explains the choice in prose naming the same identifiers, so the raw slice is satisfied
    // by a site whose wiring has been commented out.
    const start = INDEX_SRC.indexOf("async function updateStory(");
    assert.ok(start > -1, "the update_story handler was not found");

    const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
    assert.ok(end > start, "the handler has no following function to bound it");

    const handler = INDEX_SRC.slice(start, end)
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/\/\/[^\n]*/g, "");

    assert.match(handler, /updateStoryRequest\(/, "it does not call the lib");
    assert.match(handler, /LOOPCTL_ORCH_KEY/, "it does not send the orchestrator key");
    assert.ok(
      !handler.includes("exactKey"),
      "it pins the key, which would refuse a global LOOPCTL_API_KEY the gate accepts",
    );
  });
});
