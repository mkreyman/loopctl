/**
 * `escalation_list` — `GET /api/v1/escalations` (loopctl US-48.11, the escalation inbox).
 *
 * Every story of the caller's tenant parked at stage `escalated`, newest escalation first,
 * keyset-paginated. Each row says WHY in `reason_class`, which the server derives from the
 * stage-machine EDGE the story was escalated over, never from text a session wrote:
 * budget_exhausted, session_failed, triage_escalated, gate_refused, operator_released, other.
 * A budget_exhausted row also carries `run` (elapsed seconds, the wall-clock budget, the
 * branch, `work_left_behind`), read from the dispatch ledger and the runner's session-end
 * report. `escalation_reason` is the stored free text and is UNTRUSTED: the row returns it
 * raw, flagged `escalation_reason_untrusted: true`, and fenced in `escalation_reason_fenced`.
 *
 * It READS only. `resolve_escalation` with `to: "queued"` is how a row is worked again.
 *
 * ## Refusals
 *
 * - `400` — an unknown `reason_class`, a `since` that is not ISO8601, a bad `limit`, or a
 *   cursor this endpoint did not issue to this tenant.
 * - `422` — a malformed `project_id`.
 * - `401` — no key, or one that does not authenticate. `429` — rate limited.
 *
 * There is NO 403: the endpoint is `role: :agent` with the hierarchy, so every key role clears
 * it. The obvious local mistakes are refused HERE with `status: 0` (nothing sent).
 */

import { uuid } from "./delivery-loop.js";

export const REASON_CLASSES = Object.freeze([
  "budget_exhausted",
  "session_failed",
  "triage_escalated",
  "gate_refused",
  "operator_released",
  "other",
]);

export const ESCALATIONS_PATH = "/api/v1/escalations";

function refuse(body) {
  return { error: true, status: 0, body };
}

function present(value) {
  return value !== undefined && value !== null && value !== "";
}

/** `GET /api/v1/escalations`, one page, newest escalation first. */
export async function escalationList(
  { reason_class, project_id, since, cursor, limit } = {},
  { apiCall } = {},
) {
  if (present(reason_class) && !REASON_CLASSES.includes(reason_class)) {
    return refuse(`\`reason_class\` must be one of ${REASON_CLASSES.join(", ")}.`);
  }

  if (present(project_id)) {
    const bad = uuid(project_id, "project_id");
    if (bad) return bad;
  }

  if (present(since) && (typeof since !== "string" || Number.isNaN(Date.parse(since)))) {
    return refuse("`since` must be an ISO8601 timestamp, e.g. 2026-11-07T00:00:00Z.");
  }

  if (present(cursor) && typeof cursor !== "string") {
    return refuse("`cursor` must be the string a previous page returned as next_cursor.");
  }

  if (present(limit) && !(Number.isInteger(limit) && limit > 0)) {
    return refuse("`limit` must be a positive integer (at most 100).");
  }

  const query = new URLSearchParams();
  if (present(reason_class)) query.set("reason_class", reason_class);
  if (present(project_id)) query.set("project_id", project_id);
  if (present(since)) query.set("since", since);
  if (present(cursor)) query.set("cursor", cursor);
  if (present(limit)) query.set("limit", String(limit));

  // Written as a template on the constant, not `CONST + (...)`: route_coverage's resolver
  // reads a template's leading constant, and the concatenation resolved to "/" instead.
  const qs = query.toString();
  const path = qs ? `${ESCALATIONS_PATH}?${qs}` : ESCALATIONS_PATH;
  return apiCall("GET", path, null);
}
