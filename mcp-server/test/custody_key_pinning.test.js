/**
 * Key selection for the `exact_role: :orchestrator` custody verbs.
 *
 * WHAT THE PINNING IS FOR. `resolveKey` in `index.js` reads
 * `LOOPCTL_API_KEY || keyOverride || LOOPCTL_ORCH_KEY`, so the global override wins over the
 * key a tool names. An operator who set LOOPCTL_ORCH_KEY specifically for these verbs, and a
 * LOOPCTL_API_KEY of some other role for everything else, had the orchestrator key silently
 * discarded on exactly the calls they set it for. `exactKey` honours it.
 *
 * WHAT IT IS **NOT** FOR, because three generations of this comment got it wrong. It is NOT
 * that the resulting 403 misattributes the failure. `LoopctlWeb.Plugs.RequireRole` is mounted
 * FIRST on those actions and its exact-role clause (`require_role.ex:65-75`) halts via
 * `forbid/3` (`require_role.ex:112-128`) with 403, `code: "insufficient_role"`,
 * `required_roles: ["orchestrator"]` and the message "This endpoint requires the orchestrator
 * role". A halted request never reaches the controller, so it never reaches
 * `Progress.validate_not_self_verify/4` and never produces a custody 409. The role error is
 * unambiguous, it is not `self_verify_blocked`, and it is not an L6 signal. Do not write that
 * claim back in.
 *
 * WHY THE PIN IS CONDITIONAL. Pinning unconditionally breaks a working, documented
 * configuration in a minor release: 2.96.0's `README.md:70` describes LOOPCTL_API_KEY as
 * "Global API key override (if set, always used)", and LOOPCTL_API_KEY holding an
 * orchestrator-role key with no LOOPCTL_ORCH_KEY at all passes the gate — the server tests the
 * key's ROLE, not its env var. So `orchestratorKeyArgs` pins only when LOOPCTL_ORCH_KEY is set.
 *
 * The five verbs below are `exact_role: :orchestrator` in loopctl:
 *
 *   - verify / reject / force_unclaim / verify-all — `story_verification_controller.ex:29-30`
 *   - bulk mark-complete                           — `bulk_operations_controller.ex:24-25`
 *
 * WHAT IS DELIBERATELY NOT HERE. `report` (`exact_role: [:agent, :orchestrator]`) and
 * `review-complete` (`exact_role: [:orchestrator, :user]`) are LIST-form gates, and for them the
 * LOOPCTL_API_KEY fallback is load-bearing rather than a hazard: the common agent configuration
 * sets LOOPCTL_API_KEY to an agent key and no orchestrator key at all, and `report_story` works
 * today only because `resolveKey` finds it there. Note what that does NOT mean — both of these
 * hand `apiCall` LOOPCTL_ORCH_KEY as their tool-specific override, and `resolveKey` never reads
 * LOOPCTL_AGENT_KEY by name, so LOOPCTL_AGENT_KEY ALONE is not a configuration either of them
 * runs under. That is the SAME reasoning the conditional pin above applies to the five, one
 * case wider.
 *
 * Two layers: the selection is behaviour and is tested as behaviour; the wiring of each handler
 * to it is a fact about index.js with no injection seam, so it is source-pinned.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { exactKeyMissingMessage, orchestratorKeyArgs } from "../lib/custody-key.js";
import { stripComments } from "./tool-surface.js";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");

const ORCH = "lc_orch_deadbeef";
const GLOBAL = "lc_global_cafef00d";

describe("orchestratorKeyArgs — which key a custody verb sends", () => {
  test("LOOPCTL_ORCH_KEY set: sent EXACTLY, so no global key displaces it", () => {
    const args = orchestratorKeyArgs({ LOOPCTL_ORCH_KEY: ORCH, LOOPCTL_API_KEY: GLOBAL });

    assert.equal(args.override, ORCH);
    assert.equal(args.resolved, ORCH);
    assert.equal(args.options.exactKey, true, "a global LOOPCTL_API_KEY would win without this");
    assert.equal(args.options.keyHint, "LOOPCTL_ORCH_KEY");
  });

  test("LOOPCTL_ORCH_KEY alone: same, no global key needed", () => {
    const args = orchestratorKeyArgs({ LOOPCTL_ORCH_KEY: ORCH });

    assert.equal(args.override, ORCH);
    assert.equal(args.resolved, ORCH);
    assert.equal(args.options.exactKey, true);
  });

  test("LOOPCTL_API_KEY alone still reaches the gate — the pin does not break it", () => {
    // THE REGRESSION THIS EXISTS FOR. Before 2.97.0 these verbs passed no options, so
    // `resolveKey` returned LOOPCTL_API_KEY, and `LOOPCTL_API_KEY=<an orchestrator-role key>`
    // with no LOOPCTL_ORCH_KEY was a working, README-documented setup that the
    // `exact_role: :orchestrator` gate accepts. An unconditional pin refuses it locally,
    // sends nothing, and tells the operator their key is the wrong role when it is not.
    const args = orchestratorKeyArgs({ LOOPCTL_API_KEY: GLOBAL });

    assert.equal(
      args.options.exactKey,
      undefined,
      "the global key was pinned away; that is a behavioural break in a minor release",
    );
    assert.equal(
      args.override,
      undefined,
      "passing an override here would make `resolveKey` prefer it over nothing useful",
    );
    assert.equal(args.resolved, GLOBAL, "the request must still carry the global key");
  });

  test("neither set: nothing to send, and the hint names the variable to set", () => {
    const args = orchestratorKeyArgs({});

    assert.equal(args.resolved, undefined, "callers refuse locally on exactly this");
    // `exactKey` + `keyHint` is what makes `apiCall`'s missing-key branch (its `if (!key)`
    // clause, in `index.js`) name LOOPCTL_ORCH_KEY instead of defaulting to the
    // set_llm_config wording.
    assert.equal(args.options.exactKey, true);
    assert.equal(args.options.keyHint, "LOOPCTL_ORCH_KEY");
  });

  test("the missing-key message offers BOTH variables, since neither is set", () => {
    // This branch is reachable only when the hinted variable AND LOOPCTL_API_KEY are both
    // unset, so the message it replaced — "LOOPCTL_API_KEY is deliberately not a fallback for
    // it" — steered an operator away from a configuration that works.
    const message = exactKeyMissingMessage("LOOPCTL_ORCH_KEY");

    assert.match(message, /Set LOOPCTL_ORCH_KEY/, "it does not name the variable to set");
    assert.match(message, /LOOPCTL_API_KEY/, "it does not offer the global key that would work");
    assert.ok(
      !/not a fallback/.test(message),
      "it tells an operator with no keys that the global key will not work, which is false here",
    );
    // And it must not overcorrect into "any key will do".
    assert.match(message, /exact role|role exactly/, "it does not say the gate matches exactly");
  });
});

/**
 * The source of ONE top-level `async function`, bounded by the next one, WITH ITS COMMENTS
 * STRIPPED.
 *
 * The stripping is the part that makes this an assertion rather than a grep. Every one of
 * these call sites carries a comment explaining the selection, and that comment names the
 * things asserted below — so a check reading the raw slice is satisfied by a site where the
 * call has been commented OUT, which is exactly the shape a disabling edit takes. Verified by
 * mutation: without this, replacing the wiring line with a block comment left the suite green.
 */
function handlerSource(name) {
  const start = INDEX_SRC.indexOf(`\nasync function ${name}(`);
  assert.ok(start > -1, `the ${name} handler was not found`);

  // Bounded by the NEXT function rather than a named neighbour, so inserting something
  // between them cannot silently widen what this reads.
  const end = INDEX_SRC.indexOf("\nasync function ", start + 1);
  assert.ok(end > start, `${name} has no following function to bound it`);

  return stripComments(INDEX_SRC.slice(start, end));
}

const EXACT_ROLE_ORCHESTRATOR = [
  ["verify_story", "verifyStory"],
  ["reject_story", "rejectStory"],
  ["bulk_mark_complete", "bulkMarkComplete"],
  ["verify_all_in_epic", "verifyAllInEpic"],
  // #846 round 2: force_unclaim_story is on the SAME plug line as verify and reject
  // (`story_verification_controller.ex:29-30`) and was the one pinned custody verb missing
  // from this table — and, before this round, the one sending no `keyHint`, so a missing key
  // was reported as an LLM-configuration problem.
  ["force_unclaim_story", "forceUnclaimStory"],
];

describe("exact_role: :orchestrator verbs select their key through orchestratorKeyArgs", () => {
  for (const [tool, handler] of EXACT_ROLE_ORCHESTRATOR) {
    test(`${tool} selects its key through orchestratorKeyArgs, and sends what it returns`, () => {
      const source = handlerSource(handler);

      assert.match(
        source,
        /orchestratorKeyArgs\(\)/,
        `${tool} does not call orchestratorKeyArgs, so its key selection is its own`,
      );
      assert.ok(
        source.includes("orch.override"),
        `${tool} calls orchestratorKeyArgs but does not send the key it chose`,
      );
      assert.ok(
        source.includes("orch.options"),
        `${tool} drops the options, so LOOPCTL_ORCH_KEY is no longer pinned and the ` +
          `missing-key message loses its keyHint`,
      );
      assert.ok(
        !source.includes("LOOPCTL_USER_KEY"),
        `${tool} reaches for the user key, which an exact_role: :orchestrator gate refuses`,
      );
    });
  }

  test("force_unclaim_story refuses locally only when NO key is configured", () => {
    // It is the one verb in the table with a local refusal, and it must branch on `resolved`
    // — the key that will actually be sent — never on LOOPCTL_ORCH_KEY alone. Branching on the
    // env var is what would refuse the orchestrator-only-LOOPCTL_API_KEY config above.
    const source = handlerSource("forceUnclaimStory");

    assert.ok(
      source.includes("orchKey: orch.resolved"),
      "it does not pass the resolved key, so its local refusal does not match what is sent",
    );
    assert.ok(
      !/process\.env\.LOOPCTL_ORCH_KEY/.test(source),
      "it reads the env var directly again, which re-breaks the global-key configuration",
    );
  });

  test("the ones with LIST-form gates are deliberately left unpinned", () => {
    // Not an omission — see the module comment. If either of these ever becomes a
    // single-role `exact_role` gate, it joins the table above and this test goes with it.
    for (const handler of ["reportStory", "reviewComplete"]) {
      const source = handlerSource(handler);

      assert.ok(
        !source.includes("exactKey"),
        `${handler} was pinned; its gate accepts a role RANGE, and the common agent ` +
          `configuration reaches it through the LOOPCTL_API_KEY fallback`,
      );
      assert.ok(
        !source.includes("orchestratorKeyArgs"),
        `${handler} selects its key as an exact_role verb does; its gate is a role RANGE`,
      );

      // And their tool-specific key is LOOPCTL_ORCH_KEY, not LOOPCTL_AGENT_KEY. This is the
      // fact the README and both changelogs now state: `resolveKey` never reads
      // LOOPCTL_AGENT_KEY by name, so under LOOPCTL_AGENT_KEY alone these two answer "No API
      // key configured" and never reach their gate. Three copies of the docs said the
      // fallback made "an agent-key-only configuration" work; it makes LOOPCTL_API_KEY=<agent
      // key> work, which is a different setup.
      assert.ok(
        source.includes("process.env.LOOPCTL_ORCH_KEY"),
        `${handler} no longer names LOOPCTL_ORCH_KEY as its key — the docs' claim about ` +
          `which configurations reach it is now wrong and must be re-derived`,
      );
      assert.ok(
        !source.includes("LOOPCTL_AGENT_KEY"),
        `${handler} now reads LOOPCTL_AGENT_KEY, so the docs' "not agent-key-only" caveat ` +
          `is stale`,
      );
    }
  });
});
