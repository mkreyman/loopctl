/**
 * Key selection for the `exact_role: :orchestrator` custody verbs (loopctl #846 review round 2).
 *
 * WHICH VERBS. `verify`, `reject` and `force_unclaim` plus the aggregate `verify_all`
 * (`lib/loopctl_web/controllers/story_verification_controller.ex:29-30`), and bulk
 * `verify`/`reject`/`mark_complete`
 * (`lib/loopctl_web/controllers/bulk_operations_controller.ex:24-25`). All are mounted
 * `exact_role: :orchestrator`, where the role hierarchy does NOT apply: `RequireRole`'s
 * exact-role clause tests `api_key.role == exact_role` (`require_role.ex:65-75`), so a `:user`
 * or `:superadmin` key is refused there exactly as an `:agent` key is.
 *
 * WHAT THE PINNING IS FOR — and what it is NOT for.
 *
 * NOT for the error message. An earlier draft of this comment, and every copy of it that had
 * spread across this package and both changelogs, claimed a 403 from that gate "reads as a
 * custody refusal about the STORY rather than a misconfigured key". That is false and the
 * source says so: `RequireRole.forbid/3` (`require_role.ex:112-128`) halts with 403,
 * `code: "insufficient_role"`, `required_roles: ["orchestrator"]` and the message "This
 * endpoint requires the orchestrator role", and the plug is mounted FIRST, so the request
 * never reaches the controller and never reaches `Progress.validate_not_self_verify/4` where
 * the custody 409s are raised. The role error is unambiguous. Do not reintroduce that
 * justification. It came back twice after being "removed everywhere", so it is no longer swept
 * by hand: `test/no_false_403_claim.test.js` fails on any assertion of it anywhere in this
 * package or in either changelog. It admits a quotation like the one above, but only where a
 * disproof marker sits within a sentence or so of it — a whole-paragraph rule was too loose,
 * since this refutation runs a dozen lines and its closing "do not reintroduce" would have
 * excused an assertion at the far end of the very block that disproves the claim.
 *
 * What the pinning IS for is an operator's expressed configuration. `resolveKey` in
 * `index.js` reads `LOOPCTL_API_KEY || keyOverride || LOOPCTL_ORCH_KEY` — the global
 * override wins over the key the tool names. So an operator who set `LOOPCTL_ORCH_KEY`
 * specifically for these verbs AND a `LOOPCTL_API_KEY` of some other role for everything else
 * had the orchestrator key silently discarded on precisely the calls they set it for, and paid a
 * round trip to learn it. Honouring it costs nothing and is what they asked for.
 *
 * WHY IT IS NARROWED TO "WHEN THE ORCH KEY IS SET". Pinning unconditionally is a BEHAVIOURAL
 * BREAK in a minor release, and the configuration it breaks is one the shipped docs endorsed:
 * 2.96.0's `README.md:70` describes `LOOPCTL_API_KEY` as "Global API key override (if set,
 * always used)". `LOOPCTL_API_KEY` set to an orchestrator-role key, with no `LOOPCTL_ORCH_KEY`
 * at all, was working, documented, and accepted by the gate — the key's ROLE is what the server
 * tests, and it is `:orchestrator`. An unconditional pin refuses that locally, sends nothing, and
 * tells the operator their key is the wrong role when it is not. This is the same reasoning that
 * leaves `report_story` and `review_complete` unpinned in `test/custody_key_pinning.test.js`,
 * applied consistently.
 */

/**
 * The `keyOverride` and options a custody verb should hand `apiCall`, plus the key that will
 * actually be sent.
 *
 * @param {Record<string, string|undefined>} [env]
 * @returns {{override: string|undefined, options: object, resolved: string|undefined}}
 *   `override` is `apiCall`'s 4th argument, `options` its 5th, and `resolved` is the key the
 *   request will carry — `undefined` when no key is configured at all, which is the only case a
 *   caller may refuse locally on.
 */
export function orchestratorKeyArgs(env = process.env) {
  const orchKey = env.LOOPCTL_ORCH_KEY;

  if (orchKey) {
    // The operator named a key for this role. Send exactly it: `exactKey` makes `apiCall` use
    // the override verbatim instead of `resolveKey` — the `const key = exactKey ? keyOverride :
    // resolveKey(keyOverride)` line in `index.js`.
    return {
      override: orchKey,
      options: { exactKey: true, keyHint: "LOOPCTL_ORCH_KEY" },
      resolved: orchKey,
    };
  }

  const globalKey = env.LOOPCTL_API_KEY;

  if (globalKey) {
    // No orchestrator key, but a global one. This is the pre-2.97.0 configuration and it is
    // still allowed to reach the gate: if that key is orchestrator-role it passes, and if it is
    // not, the server's own 403 names the required role. Refusing it here would break a working
    // setup to pre-empt an error the server already reports correctly.
    return { override: undefined, options: {}, resolved: globalKey };
  }

  // Nothing configured. Pin anyway, so `apiCall`'s missing-key branch (`if (!key)`, in
  // `index.js`) takes the `keyHint` path and names LOOPCTL_ORCH_KEY rather than falling back to
  // the LLM-config default. Callers that refuse locally (see `forceUnclaimStory`) branch on
  // `resolved` being undefined.
  return {
    override: undefined,
    options: { exactKey: true, keyHint: "LOOPCTL_ORCH_KEY" },
    resolved: undefined,
  };
}

/**
 * What `apiCall` says when an `exactKey` site names a variable (`keyHint`) and no key is
 * configured at all.
 *
 * The message it replaced said "LOOPCTL_API_KEY is deliberately not a fallback for it", which
 * is now false guidance: this branch is reached only when NEITHER the hinted variable nor
 * LOOPCTL_API_KEY is set, and setting LOOPCTL_API_KEY to a key of the right role IS a working
 * configuration (see `orchestratorKeyArgs`). Telling an operator with no keys at all that one
 * of their two options does not work sends them the long way round.
 *
 * What it must NOT say instead is that any key will do: the gate matches the role exactly, so
 * a higher-privileged key is refused there like any other non-member.
 */
export function exactKeyMissingMessage(keyHint) {
  return (
    `No API key configured. Set ${keyHint} — or LOOPCTL_API_KEY — to a key of the exact role ` +
    `this endpoint requires; its gate matches the role exactly, so a higher-privileged key is ` +
    `refused there like any other. When ${keyHint} is set it is the key sent, and a global ` +
    `LOOPCTL_API_KEY does not displace it.`
  );
}
