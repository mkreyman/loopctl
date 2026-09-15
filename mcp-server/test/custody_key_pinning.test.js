/**
 * The `exact_role`-gated custody verbs are pinned to LOOPCTL_ORCH_KEY, EXACTLY.
 *
 * `resolveKey` (index.js) prefers a global LOOPCTL_API_KEY over the key a tool names, which is
 * right for the many endpoints that take a role RANGE. It is wrong for an `exact_role` gate,
 * where the hierarchy does not apply: a user or superadmin key is 403'd there exactly as an
 * agent key is (`LoopctlWeb.Plugs.RequireRole`, and CLAUDE.md's role-hierarchy table). So a
 * global key of any other role silently goes out under the wrong principal, and the 403 that
 * comes back reads as a custody refusal ABOUT THE STORY — self_verify_blocked's neighbourhood —
 * rather than as the key being the wrong one. That is a misdiagnosis of an L4 signal, which is
 * the one class of error this product must not manufacture.
 *
 * The four verbs below are `exact_role: :orchestrator` in loopctl:
 *
 *   - verify / reject / verify-all — `story_verification_controller.ex:29-30`
 *   - bulk mark-complete           — `bulk_operations_controller.ex:24-25`
 *
 * WHAT IS DELIBERATELY NOT HERE. `report` (`exact_role: [:agent, :orchestrator]`) and
 * `review-complete` (`exact_role: [:orchestrator, :user]`) are LIST-form gates, and for them the
 * LOOPCTL_API_KEY fallback is load-bearing rather than a hazard: the common agent configuration
 * sets LOOPCTL_API_KEY to an agent key and no orchestrator key at all, and `report` works today
 * only because `resolveKey` finds it. Pinning those would break a working configuration to
 * prevent a 403 that names the role correctly anyway.
 *
 * Source-pinned, because the thing being asserted is a wiring fact about index.js and there is
 * no seam to inject: each handler builds its own `apiCall` arguments inline.
 *
 * Run: node --test test/*.test.js
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = readFileSync(path.join(DIR, "..", "index.js"), "utf8");

/**
 * The source of ONE top-level `async function`, bounded by the next one, WITH ITS COMMENTS
 * STRIPPED.
 *
 * The stripping is the part that makes this an assertion rather than a grep. Every one of
 * these call sites carries a comment explaining why the key is pinned, and that comment names
 * `exactKey` — so a check reading the raw slice is satisfied by a site where the option has
 * been commented OUT, which is exactly the shape a disabling edit takes. Verified by mutation:
 * without this, replacing the option line with `/* ... ` left the suite green.
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

/** Line and block comments out; string contents are left alone (none here carry code). */
function stripComments(source) {
  return source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/[^\n]*/g, "");
}

const EXACT_ROLE_ORCHESTRATOR = [
  ["verify_story", "verifyStory"],
  ["reject_story", "rejectStory"],
  ["bulk_mark_complete", "bulkMarkComplete"],
  ["verify_all_in_epic", "verifyAllInEpic"],
];

describe("exact_role: :orchestrator verbs are pinned to the ORCH key", () => {
  for (const [tool, handler] of EXACT_ROLE_ORCHESTRATOR) {
    test(`${tool} passes exactKey, so no global LOOPCTL_API_KEY substitutes`, () => {
      const source = handlerSource(handler);

      // `\b` matters: a bare `includes` also matches `LOOPCTL_ORCH_KEY_X`, so renaming the
      // variable to something that does not exist would have read as pinned.
      assert.match(
        source,
        /process\.env\.LOOPCTL_ORCH_KEY\b/,
        `${tool} does not read process.env.LOOPCTL_ORCH_KEY`,
      );
      assert.ok(
        source.includes("exactKey: true"),
        `${tool} does not pin the key exactly — a global LOOPCTL_API_KEY of any other role ` +
          `would go out under it and take a 403 attributed to the wrong cause`,
      );
    });

    test(`${tool}'s missing-key message names LOOPCTL_ORCH_KEY, not the LLM one`, () => {
      // apiCall's exactKey branch defaults to "Set LOOPCTL_USER_KEY ... to manage LLM
      // configuration", which is right for set_llm_config and nonsense for a custody verb.
      // `keyHint` is what makes the refusal name the variable that is actually missing.
      const source = handlerSource(handler);

      assert.ok(
        source.includes('keyHint: "LOOPCTL_ORCH_KEY"'),
        `${tool} pins the key but would report the missing one as an LLM-config problem`,
      );
    });
  }

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
    }
  });
});
