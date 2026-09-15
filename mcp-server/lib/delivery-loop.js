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
 *   - `force_unclaim_story` is gated `exact_role: :orchestrator`, so it needs the ORCH key and
 *     a higher-privileged one does NOT substitute: a `:user` or `:superadmin` key is 403'd
 *     there exactly as an agent key is. That is a chain-of-custody gate, not an oversight.
 *   - `story_stage` is a read and takes whatever key the caller has.
 *
 * SINGLE SOURCE OF TRUTH: `index.js` injects `apiCall`, and the unit suite runs this code
 * against a recording fake.
 */

const MISSING_USER_KEY =
  "LOOPCTL_USER_KEY is required: this verb claims a story and mints a custody dispatch, " +
  "which only an unlineaged user key may do.";

const MISSING_ORCH_KEY =
  "LOOPCTL_ORCH_KEY is required: force-unclaim is gated `exact_role: :orchestrator`, so a " +
  "user or superadmin key is 403'd there like any other non-member. A higher-privileged key " +
  "is not a way past it.";

function refuse(body) {
  return { error: true, status: 0, body };
}

/**
 * Every id this module has interpolates into a PATH, and the endpoint behind it casts
 * nothing: `Progress.force_unclaim_story/3` reaches `lock_story/2` (`progress.ex:3467`),
 * which puts `story_id` straight into an Ecto `where`, so a non-UUID raises
 * `Ecto.Query.CastError` and the caller gets a 500 instead of a usable refusal. The shape
 * check therefore belongs here, where it can say what is wrong.
 *
 * The refusal names the SHAPE and never echoes the value. A malformed id is frequently a
 * token, a path or a pasted line that landed in the wrong argument, and a tool result goes
 * into the transcript.
 */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function uuid(value, field) {
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
 * ## IT FREES THE STAGE. IT DOES NOT MAKE THE STORY PLACEABLE.
 *
 * This comment used to say the second half was "what makes the story PLACEABLE again", and
 * that is false. `Placement.claimable/2` (`placement.ex:482-490`) wants `agent_status ==
 * :contracted` AND stage `queued`; the release leaves the story at `:pending`, and
 * `@valid_transitions` (`progress.ex:3480`) has `pending: :contracted` and nothing else — so
 * `place_dispatch` run straight afterwards answers the IDENTICAL 409 `invalid_transition`.
 *
 * The remedy is two steps and the tool descriptions say so: `force_unclaim_story`, then
 * `contract_story`, then `place_dispatch`. (`resolve_escalation` is the one that does both for
 * you: `Escalations.prepare_story/5` releases AND re-contracts on the `queued` route,
 * `escalations.ex:335-342`.)
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
 * ORCHESTRATOR key, and exactly that: the action is `exact_role: :orchestrator`, so a user or
 * superadmin key is refused. `LOOPCTL_API_KEY` is deliberately NOT consulted as a fallback
 * (`index.js` passes `exactKey`), because a global key of some other role would produce a 403
 * that reads like the story being unclaimable rather than the key being wrong.
 */
export async function forceUnclaimStory({ story_id } = {}, { orchKey, apiCall } = {}) {
  if (!orchKey) return refuse(MISSING_ORCH_KEY);

  const bad = uuid(story_id, "story_id");
  if (bad) return bad;

  return apiCall("POST", forceUnclaimPath(story_id), null);
}
