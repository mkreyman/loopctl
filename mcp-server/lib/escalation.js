/**
 * Story escalation (loopctl #803, design §8; MCP side under #809).
 *
 * `escalate_story` is the POSITIVE AFFORDANCE an unattended session has instead of a
 * question. A headless run has no AskUserQuestion at all, and nothing fires when the model
 * wanted to ask — no tool call is attempted, so no hook sees anything — which is why the
 * session must be able to DO something rather than be detected wanting to.
 *
 * It is one-way from the session's side: the story parks at the `escalated` delivery stage
 * and only a HUMAN principal moves it off. So the result leads with a line saying to STOP,
 * because a session that escalates and keeps working is the failure this exists to prevent
 * and a bare JSON body does not say so.
 *
 * SINGLE SOURCE OF TRUTH. index.js injects `apiCall`; the unit suite runs this code with a
 * recording fake. The KEY is selected here, from the injected env, so the key an escalation
 * travels on is testable behaviour rather than a source pattern — and it must be the AGENT
 * key, because the endpoint is `exact_role: :agent`: the human key that RESOLVES an
 * escalation is 403'd, which is the separation the route exists inside.
 *
 * Only `story_id` and a non-empty `reason` are validated client-side. Everything else is the
 * server's judgement and passes through unchanged: 409 stale_claim_epoch (the claim ended —
 * stop working it), 409 not_claimant, 404 unknown_story_stage, 400 for a malformed epoch.
 */

export function escalatePath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/escalate`;
}

/**
 * `POST /api/v1/stories/:id/escalate {claim_epoch, reason, payload?}` on the AGENT key.
 * `claim_epoch` is forwarded exactly as given, and `payload` is omitted when absent rather
 * than sent as null.
 */
export async function escalateStory(
  { story_id, claim_epoch, reason, payload } = {},
  { apiCall, env = process.env } = {},
) {
  if (typeof story_id !== "string" || story_id.trim() === "") {
    return { error: true, status: 0, body: "`story_id` is required." };
  }
  if (typeof reason !== "string" || reason.trim() === "") {
    return {
      error: true,
      status: 0,
      body: "`reason` is required: say what a human has to decide, in your own words.",
    };
  }

  const body = { claim_epoch, reason };
  if (payload !== undefined && payload !== null) body.payload = payload;

  return apiCall("POST", escalatePath(story_id), body, env.LOOPCTL_AGENT_KEY);
}

/**
 * The line that leads a successful escalation, or null on a refusal. It says STOP, because
 * the whole point of the call is that the session hands the decision over and does no more
 * work on the story.
 */
export function escalationNotice(result) {
  const stage = result && result.error !== true ? result.stage : null;
  if (!stage || stage.stage !== "escalated") return null;

  return (
    "ESCALATED: this story is parked for a human and only a human moves it off. " +
    "STOP working it now — do not implement, do not open a PR, do not pick the decision " +
    "yourself. Report that you escalated and why."
  );
}
