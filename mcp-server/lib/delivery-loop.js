/**
 * The delivery loop's OPERATOR verbs (loopctl #803, #850, #846).
 *
 * These tools exist because the endpoints behind them were unreachable from any session on the
 * fleet. `POST /api/v1/runners/:runner_id/dispatches` shipped with #842 and no tool called it;
 * `curl` at loopctl is refused by the fleet's own guardrail, deliberately; so
 * the only way to place a dispatch was a shell on the production node. That is the same defect
 * as `place/4` shipping with no caller, failing one layer later — the trigger exists and
 * nothing outside the app can pull it.
 *
 * Mark's rule, 2026-09-15: an operator-facing endpoint is not done until an MCP tool calls it,
 * in the same change. These are that rule applied to the verbs the loop needs to be RUNNABLE
 * (place a dispatch), OBSERVABLE (read a story's stage) and RECOVERABLE (resolve an
 * escalation, free a story a runner refused).
 *
 * KEY SELECTION is behaviour, not a convention, so it lives here where a test can see it:
 *
 *   - `place_dispatch` mints a custody dispatch and claims a story, so it needs the USER key —
 *     an unlineaged `:user` principal is the only one `place/4`'s lineage ceiling lets root a
 *     tree, and an agent key is refused `insufficient_role` before anything is written.
 *   - `resolve_escalation` is the HUMAN half of the escalation pair: a `:user` key no dispatch
 *     minted. The agent key that raises an escalation is 403'd on it by design.
 *   - `force_unclaim_story` is gated `exact_role: :orchestrator`
 *     (`story_verification_controller.ex:29-30`), so it needs an ORCHESTRATOR-ROLE key and a
 *     higher-privileged one does NOT substitute: `RequireRole`'s exact-role clause tests
 *     `api_key.role == exact_role` (`require_role.ex:65-75`), so a `:user` or `:superadmin`
 *     key is 403'd there exactly as an agent key is. That is a chain-of-custody gate, not an
 *     oversight. WHICH ENV VAR carries that key is a separate question, and `index.js` decides
 *     it in `lib/custody-key.js`: LOOPCTL_ORCH_KEY when set, else LOOPCTL_API_KEY.
 *   - `story_stage` is a read and takes whatever key the caller has.
 *
 * SINGLE SOURCE OF TRUTH: `index.js` injects `apiCall`, and the unit suite runs this code
 * against a recording fake.
 */

const MISSING_USER_KEY =
  "LOOPCTL_USER_KEY is required: this verb claims a story and mints a custody dispatch, " +
  "which only an unlineaged user key may do.";

const MISSING_ORCH_KEY =
  "No API key is configured. Set LOOPCTL_ORCH_KEY to an orchestrator-role key (or " +
  "LOOPCTL_API_KEY to one). Force-unclaim is gated `exact_role: :orchestrator`, so a user or " +
  "superadmin key is 403'd there like any other non-member: a higher-privileged key is not a " +
  "way past it.";

function refuse(body) {
  return { error: true, status: 0, body };
}

/**
 * A client-side shape check on the ids that go into a URL PATH: `story_id` and `runner_id`.
 *
 * EXPORTED, because it is one check and not a pattern to copy. `update_story`
 * (`lib/story-update.js`) interpolates a `story_id` into a path exactly as the verbs below do
 * and shipped without it, which is the way a rule stated in a comment decays: the comment says
 * "any argument interpolated into a URL path", and the check was reachable only from this file.
 * A second implementation would give the same parameter two different refusals depending on
 * which tool took it — the thing the paragraph on `place_dispatch`'s `story_id` below already
 * refuses to do.
 *
 * NOT on `place_dispatch`'s `dispatch_id`, which is an id and is forwarded unchecked. That is a
 * decision and not an omission: it travels in the request BODY, and `Placement.place/4` casts it
 * with `fetch_uuid/2` (`lib/loopctl/delivery/placement.ex:786-791`) as the second clause of its
 * `with` — before the caller is resolved, before anything is minted and before the claim — so a
 * malformed one answers `422 invalid_payload` with `details: ["dispatch_id: must be a UUID"]`
 * (`lib/loopctl_web/controllers/dispatch_placement_controller.ex:321-326`). That names the
 * parameter and the shape, costs nothing on the server, and is the opposite of the ambiguity
 * below. There is nothing here for a client check to disambiguate. An earlier draft of this
 * comment said the check covered "every id these verbs take"; it never did.
 *
 * WHY THE PATH IDS DO NEED IT — stated correctly, since an earlier draft of this comment said a
 * malformed id made the server "500", and it does not. loopctl has a deliberate backstop:
 * `defimpl Plug.Exception, for: Ecto.Query.CastError` maps it to 404
 * (`lib/loopctl_web/plugs/cast_error_handler.ex:32-35` — the file also carries an
 * `Ecto.CastError` impl at `:27-30` and an `Ecto.ChangeError` impl at `:37-42`; the query path
 * below raises the `Ecto.Query.CastError` one), pinned by
 * `test/loopctl_web/plugs/cast_error_handler_test.exs:9-12`. What the caller actually gets is
 * `{"error": {"status": 404, "message": "Not found"}}` — the generic body
 * `LoopctlWeb.ErrorJSON.render("404.json", …)` emits
 * (`lib/loopctl_web/controllers/error_json.ex:13-15`, wired by `config/config.exs:344-347`).
 *
 * That 404 is the problem, not a 500. It is BYTE-IDENTICAL to the 404 for a perfectly
 * well-formed id that names no story — `FallbackController` answers `{:error, :not_found}` with
 * the same `%{error: %{status: 404, message: "Not found"}}`
 * (`lib/loopctl_web/fallback_controller.ex:74-78`) — so it cannot tell an operator which
 * of the two happened, and the two have opposite remedies: re-read the argument you passed, or
 * go find the right story. The check here can tell them apart, and does it without a round trip.
 *
 * SCOPE OF THAT TRACE. The path read end to end is force-unclaim:
 * `Progress.force_unclaim_story/3` reaches `lock_story/2` (`lib/loopctl/progress.ex:3467-3470`),
 * which puts `story_id` straight into a `where` against a `:binary_id` column with no cast. The
 * other verbs are NOT claimed to reach that same code. They do not need to: a shape check is
 * worth its line on any argument that is interpolated into a URL path and must be a UUID,
 * whatever the server would do with a value that is not one. `place_dispatch`'s `story_id` is
 * the one exception in the other direction — it travels in the body, like `dispatch_id` — and it
 * is checked because `story_id` is a PATH id in the three sibling verbs and `uuid()` is one
 * shared check: giving the same parameter two different refusals depending on which verb took it
 * is worse than checking it once too often.
 *
 * THE REFUSAL CARRIES `status: 0`, NOT 404, and that is deliberate. Every local refusal in this
 * client uses it — `refuse()` below, `apiCall`'s missing-key branch and its network/timeout
 * branches (`index.js`) — and it means ONE thing: no request was sent, so no server said
 * anything. The whole result object is JSON-stringified into the tool output (`toContent`,
 * `index.js`), so a reader sees that 0. Stamping 404 on it instead would make a local refusal
 * indistinguishable from the server's answer, which is precisely the ambiguity this check
 * exists to remove. A caller branching on the status therefore sees `0` where it previously saw
 * `404`; that is a shape change and the 2.97.0 CHANGELOG entry says so.
 *
 * The refusal names the SHAPE and never echoes the value. A malformed id is frequently a
 * token, a path or a pasted line that landed in the wrong argument, and a tool result goes
 * into the transcript.
 */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function uuid(value, field) {
  if (typeof value !== "string" || value.trim() === "") {
    return refuse(`\`${field}\` is required.`);
  }

  if (!UUID_RE.test(value)) {
    return refuse(
      `\`${field}\` must be a UUID (8-4-4-4 hex digits then 12, lowercase or upper). ` +
        `Got a ${value.length}-character string that is not one. The value is not repeated ` +
        `here: a malformed id is often something pasted into the wrong argument, and a tool ` +
        `result lands in the transcript.`,
    );
  }

  return null;
}

export function placementPath(runnerId) {
  return `/api/v1/runners/${encodeURIComponent(runnerId)}/dispatches`;
}

export function stagePath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/stage`;
}

export function resolvePath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/stage/resolve`;
}

/** Note the HYPHEN: the route is `force-unclaim`, not `force_unclaim`. */
export function forceUnclaimPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/force-unclaim`;
}

/**
 * `POST /api/v1/runners/:runner_id/dispatches`: claim a queued story and push it to a runner.
 *
 * `dispatch_id` is generated here when the caller does not supply one, because the endpoint is
 * idempotent ON THAT ID: a retry carrying the same one re-sends the frame rather than starting
 * a second session, and a caller that cannot name it cannot retry safely. A caller repeating a
 * call after a timeout should pass the id it used the first time.
 *
 * `repo`, `base_branch`, `branch`, `wall_clock_seconds` and `max_turns` are REQUIRED BY THE
 * CONTRACT and are not required here, because loopctl fills each one from its own records
 * (`Loopctl.Delivery.DispatchPayload`): the repository and its base branch from the project's
 * intake source, the branch from the story, the budgets from the operator's configuration. An
 * override passed here wins. This is not a convenience — a payload missing one of them is
 * refused by `cast_dispatch/1`, which runs AFTER the claim and two immutable chain entries, so
 * a client that had to know a repository name would pay for that mistake every time.
 *
 * The STORY OBJECT is not a parameter and may not be: loopctl builds it from its own rows, and
 * a caller-supplied one is refused `story_not_accepted` — a control plane able to hand a runner
 * prose is able to run anything on that machine.
 */
export async function placeDispatch(
  {
    story_id,
    runner_id,
    dispatch_id,
    kind = "implement",
    repo,
    branch,
    base_branch,
    wall_clock_seconds,
    max_turns,
  } = {},
  { userKey, apiCall, uuidv4 } = {},
) {
  if (!userKey) return refuse(MISSING_USER_KEY);

  const bad = uuid(story_id, "story_id") || uuid(runner_id, "runner_id");
  if (bad) return bad;

  const body = {
    dispatch_id: dispatch_id || uuidv4(),
    story_id,
    kind,
  };

  for (const [key, value] of Object.entries({
    repo,
    branch,
    base_branch,
    wall_clock_seconds,
    max_turns,
  })) {
    if (value !== undefined && value !== null) body[key] = value;
  }

  return apiCall("POST", placementPath(runner_id), body);
}

/** `GET /api/v1/stories/:id/stage`: where the story is in the delivery machine, or null. */
export async function storyStage({ story_id } = {}, { apiCall } = {}) {
  const bad = uuid(story_id, "story_id");
  if (bad) return bad;

  return apiCall("GET", stagePath(story_id), null);
}

/**
 * `POST /api/v1/stories/:id/stage/resolve`: move an escalated story off `escalated`, as a
 * human. `to` is `queued`, `done` or `failed`.
 */
export async function resolveEscalation({ story_id, to, reason } = {}, { userKey, apiCall } = {}) {
  if (!userKey) {
    return refuse(
      "LOOPCTL_USER_KEY is required: only a human principal — a user key no dispatch " +
        "minted — may resolve an escalation. That is the separation that stops a session " +
        "clearing the escalation it raised.",
    );
  }

  const bad = uuid(story_id, "story_id");
  if (bad) return bad;

  if (!["queued", "done", "failed"].includes(to)) {
    return refuse("`to` must be one of: queued (work it again), done, failed.");
  }

  const body = { to };
  if (typeof reason === "string" && reason.trim() !== "") body.reason = reason;

  return apiCall("POST", resolvePath(story_id), body);
}

/**
 * `POST /api/v1/stories/:id/force-unclaim`: take a story back off the agent holding it.
 *
 * TWO things happen. `force_unclaim_story/3` resets `agent_status` to `pending` and clears
 * `assigned_agent_id` (`release_claim_changes/1`, `progress.ex:1438`); then, in the SAME
 * transaction, `Stages.follow_release/5` makes the delivery stage row follow the release —
 * from any stage a claim holds (`claimed`, `worktree`, `implementing`, `reviewing`, `pr_open`,
 * `ci`) back to `queued`, rebound to the new claim epoch.
 *
 * ## A DELIVERY STORY GOES TO `escalated`, NOT BACK TO THE QUEUE
 *
 * An operator taking a story back is a human decision (loopctl US-44.4, #877), so when the
 * release leaves the delivery stage row at `queued`, `Stages.follow_release/5` escalates it over
 * the control-only `{queued, escalated, operator_released}` edge in the same transaction. It
 * spends no attempt against the retry ceiling. The story is never left at `queued` + `pending`,
 * which `Placement.claimable/2` refuses and nothing re-contracted.
 *
 * To put it back to work: `resolve_escalation` with `to: queued`, which releases (a no-op by
 * then) AND re-contracts (`Escalations.prepare_story/6`). A story with no stage row is simply
 * left `pending`, exactly as before.
 *
 * ## WHEN A STORY IS ACTUALLY PARKED
 *
 * Not on an ordinary refusal — that path self-heals. `Placement.place/4` answers a
 * `Runners.dispatch/3` refusal INLINE with `undo_claim/5` (`placement.ex:562`, `:706-711`),
 * which releases the claim through this same function, unrecords the session dispatch and
 * revokes it. If that release itself fails, the claim lease is a further backstop:
 * `Progress.reclaim_expired_claim/3` (`progress.ex:1612`) releases over `:runner_lost` and
 * requeues the stage, swept by `ReclaimExpiredClaimsWorker` every five minutes once
 * `claimed_until` has passed.
 *
 * So a story sitting at `claimed` with nobody on it is the RESIDUE OF A FAILED COMPENSATION,
 * not what a refusal normally leaves. Reach for this tool to get the story back now instead of
 * at lease expiry, or when both of those have left it held.
 *
 * No request body — the story is named in the path.
 *
 * ORCHESTRATOR ROLE, and exactly that: the action is `exact_role: :orchestrator`
 * (`story_verification_controller.ex:29-30`), so a user or superadmin key is refused —
 * `RequireRole`'s exact-role clause tests `api_key.role == exact_role`
 * (`require_role.ex:65-75`).
 *
 * WHICH ENV VAR supplies that key is `index.js`'s call, made in `lib/custody-key.js`:
 * LOOPCTL_ORCH_KEY is sent EXACTLY when it is set, so `resolveKey` cannot discard an
 * operator's deliberate choice in favour of a global LOOPCTL_API_KEY; when it is not set, the
 * global key still goes, because an orchestrator-role LOOPCTL_API_KEY was a working and
 * documented configuration before 2.97.0. The refusal below fires only when NEITHER is set.
 *
 * NOT because the 403 would be confusing. An earlier draft of this paragraph said a wrong-role
 * global key "would produce a 403 that reads like the story being unclaimable rather than the
 * key being wrong". That is false: `RequireRole` is mounted FIRST and halts with 403,
 * `code: "insufficient_role"`, `required_roles: ["orchestrator"]` and "This endpoint requires
 * the orchestrator role" (`require_role.ex:112-128`), so the request never reaches the
 * controller and never reaches the custody 409s in `Progress`. The role error names the role.
 */
export async function forceUnclaimStory({ story_id } = {}, { orchKey, apiCall } = {}) {
  if (!orchKey) return refuse(MISSING_ORCH_KEY);

  const bad = uuid(story_id, "story_id");
  if (bad) return bad;

  return apiCall("POST", forceUnclaimPath(story_id), null);
}

export function mergePreconditionPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/merge-precondition`;
}

/**
 * `merge_precondition` (epic 44, US-44.1): the second run of both delivery gates over the real
 * pull request. `exact_role: [:orchestrator, :user]`, so it takes the ORCH key the way
 * `force_unclaim_story` does. It sends no `trio_outputs`: since contract 1.15.0 Gate A reads
 * the lens verdicts triage persisted, and a trio sent here would be ignored.
 */
export async function mergePrecondition(
  { story_id, claim_epoch, effect_proof } = {},
  { orchKey, apiCall } = {},
) {
  if (!orchKey) return refuse(MISSING_ORCH_KEY);

  const bad = uuid(story_id, "story_id");
  if (bad) return bad;

  if (!Number.isInteger(claim_epoch) || claim_epoch < 0) {
    return refuse("claim_epoch must be a non-negative integer: the epoch the caller acts under.");
  }

  const body = { claim_epoch };
  if (effect_proof && typeof effect_proof === "object") body.effect_proof = effect_proof;

  return apiCall("POST", mergePreconditionPath(story_id), body);
}
