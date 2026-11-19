/**
 * `chg_findings`, `chg_finding_clear` (loopctl US-51.6) and `chg_finding_dismiss` (#1064): the chg
 * feedback loop's findings —
 * `GET /api/v1/chg_findings`, `POST /api/v1/chg_findings/:id/clear` and
 * `POST /api/v1/chg_findings/:id/dismiss`. Dismissing closes a finding filed in error and is
 * gated like clear: a user key, used exactly.
 *
 * A finding is a problem the nightly sweep derived from the chg ledger (a selection miss, a
 * flaky test, a merge with no review, a stuck change, a silent ledger sender), filed as a
 * GitHub issue that the delivery loop then fixes.
 *
 * The list is a READ, `role: :agent` with the hierarchy, so the handler passes
 * LOOPCTL_AGENT_KEY as an override and `resolveKey`'s order holds. Clearing an ESCALATED
 * finding sends it round the loop again, so it is `role: :user` on a human-anchored tenant and
 * takes the EXACT user key, like the runner tools.
 */

export const STATES = ["queued", "filed", "fixed", "closed", "escalated"];
export const KINDS = [
  "selection_miss",
  "flaky_test",
  "missing_review",
  "stuck_change",
  "source_silent",
];
export const LIST_CAP = 200;

export const MISSING_USER_KEY =
  "No user-role API key configured. Set LOOPCTL_USER_KEY to a user-role key to clear a chg " +
  "finding: clearing sends an escalated problem back to the loop, so it is a person's act and " +
  "the endpoint refuses agent and orchestrator keys.";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function refuse(body) {
  return { error: true, status: 0, body };
}

/** `GET /api/v1/chg_findings`, with the optional `state`, `kind`, `repo`, `limit`. */
export async function chgFindings(args = {}, { apiCall } = {}) {
  const { state, kind, repo, limit } = args;

  if (state !== undefined && state !== null && !STATES.includes(state)) {
    return refuse(`\`state\` must be one of ${STATES.join(", ")}.`);
  }
  if (kind !== undefined && kind !== null && !KINDS.includes(kind)) {
    return refuse(`\`kind\` must be one of ${KINDS.join(", ")}.`);
  }
  if (repo !== undefined && repo !== null && typeof repo !== "string") {
    return refuse("`repo` must be a string.");
  }
  if (
    limit !== undefined &&
    limit !== null &&
    !(Number.isInteger(limit) && limit >= 1 && limit <= LIST_CAP)
  ) {
    return refuse(`\`limit\` must be an integer from 1 to ${LIST_CAP}.`);
  }

  const qs = new URLSearchParams();
  if (typeof state === "string") qs.set("state", state);
  if (typeof kind === "string") qs.set("kind", kind);
  if (typeof repo === "string" && repo !== "") qs.set("repo", repo);
  if (Number.isInteger(limit)) qs.set("limit", String(limit));

  const query = qs.toString();
  return apiCall("GET", `/api/v1/chg_findings${query ? `?${query}` : ""}`, null);
}

/** `POST /api/v1/chg_findings/:id/clear` with the exact user key. */
export async function chgFindingClear({ finding_id } = {}, { userKey, apiCall } = {}) {
  if (!userKey) return refuse(MISSING_USER_KEY);

  if (typeof finding_id !== "string" || !UUID.test(finding_id)) {
    return refuse("`finding_id` is required: the finding's UUID, from chg_findings.");
  }

  return apiCall("POST", `/api/v1/chg_findings/${encodeURIComponent(finding_id)}/clear`, {});
}

export const DISMISS_REASON_MAX = 500;

/** `POST /api/v1/chg_findings/:id/dismiss` with the exact user key and a reason (loopctl #1064). */
export async function chgFindingDismiss({ finding_id, reason } = {}, { userKey, apiCall } = {}) {
  if (!userKey) return refuse(MISSING_USER_KEY);

  if (typeof finding_id !== "string" || !UUID.test(finding_id)) {
    return refuse("`finding_id` is required: the finding's UUID, from chg_findings.");
  }
  if (
    typeof reason !== "string" ||
    reason.trim() === "" ||
    reason.trim().length > DISMISS_REASON_MAX
  ) {
    return refuse(`\`reason\` is required: 1 to ${DISMISS_REASON_MAX} characters.`);
  }

  return apiCall("POST", `/api/v1/chg_findings/${encodeURIComponent(finding_id)}/dismiss`, {
    reason,
  });
}
