/**
 * The delivery loop's OPERATOR verbs (loopctl #803, #850).
 *
 * Three tools, and they exist because the endpoints behind them were unreachable from any
 * session on the fleet. `POST /api/v1/runners/:runner_id/dispatches` shipped with #842 and no
 * tool called it; `curl` at loopctl is refused by the fleet's own guardrail, deliberately; so
 * the only way to place a dispatch was a shell on the production node. That is the same defect
 * as `place/4` shipping with no caller, failing one layer later — the trigger exists and
 * nothing outside the app can pull it.
 *
 * Mark's rule, 2026-09-15: an operator-facing endpoint is not done until an MCP tool calls it,
 * in the same change. These are that rule applied to the three verbs the loop needs to be
 * RUNNABLE (place a dispatch) and OBSERVABLE (read a story's stage, resolve an escalation).
 *
 * KEY SELECTION is behaviour, not a convention, so it lives here where a test can see it:
 *
 *   - `place_dispatch` mints a custody dispatch and claims a story, so it needs the USER key —
 *     an unlineaged `:user` principal is the only one `place/4`'s lineage ceiling lets root a
 *     tree, and an agent key is refused `insufficient_role` before anything is written.
 *   - `resolve_escalation` is the HUMAN half of the escalation pair: a `:user` key no dispatch
 *     minted. The agent key that raises an escalation is 403'd on it by design.
 *   - `story_stage` is a read and takes whatever key the caller has.
 *
 * SINGLE SOURCE OF TRUTH: `index.js` injects `apiCall`, and the unit suite runs this code
 * against a recording fake.
 */

const MISSING_USER_KEY =
  "LOOPCTL_USER_KEY is required: this verb claims a story and mints a custody dispatch, " +
  "which only an unlineaged user key may do.";

function refuse(body) {
  return { error: true, status: 0, body };
}

function uuid(value, field) {
  return typeof value === "string" && value.trim() !== ""
    ? null
    : refuse(`\`${field}\` is required.`);
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
