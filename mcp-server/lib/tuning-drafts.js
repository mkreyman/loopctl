/**
 * `tuning_drafts` and `tuning_draft_mark_landed` (loopctl US-48.13): the improvement loop's
 * operator surface — `GET /api/v1/tuning_drafts` and `POST /api/v1/tuning_drafts/:id/landed`.
 *
 * A tuning draft is what a runner session (agent spec `spec_tuner@1`) proposed for a TARGET
 * spec from that spec's failed runs: a prompt-template diff, new eval cases, and the eval
 * scores of both templates. loopctl decides the draft's status itself (`proposed` only when the
 * proposal is strictly better and no existing case regressed) and NEVER applies one: the
 * template changes only through a pull request a person merges, after which they mark the
 * draft landed here, naming that PR.
 *
 * Both endpoints are `role: :user` — the traces carry customer ticket text, and landing is a
 * person's record that they merged a prompt change — so this takes the EXACT user key, like
 * the runner tools: a global LOOPCTL_API_KEY must not stand in for it.
 */

export const MISSING_USER_KEY =
  "No user-role API key configured. Set LOOPCTL_USER_KEY to a user-role key to use the " +
  "tuning draft tools: the traces carry customer ticket text and landing records a person's " +
  "merge, so both endpoints refuse agent and orchestrator keys.";

export const STATUSES = ["pending", "proposed", "rejected", "landed", "superseded", "abandoned"];

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PR_URL = /^https:\/\/github\.com\/[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}\/pull\/[1-9][0-9]{0,9}$/;

function refuse(body) {
  return { error: true, status: 0, body };
}

export const TUNING_DRAFTS_PATH = "/api/v1/tuning_drafts";

export function landedPath(id) {
  return `${TUNING_DRAFTS_PATH}/${encodeURIComponent(id)}/landed`;
}

/** `GET /api/v1/tuning_drafts`, one page, newest first. */
export async function tuningDrafts(
  { project_id, spec_id, status, cursor, limit } = {},
  { userKey, apiCall } = {},
) {
  if (!userKey) return refuse(MISSING_USER_KEY);

  if (project_id !== undefined && project_id !== null && !(typeof project_id === "string" && UUID.test(project_id))) {
    return refuse("`project_id` must be a project UUID.");
  }

  if (spec_id !== undefined && spec_id !== null && !(typeof spec_id === "string" && /^[a-z][a-z0-9_]{0,63}$/.test(spec_id))) {
    return refuse("`spec_id` must be a spec id, e.g. `triage`.");
  }

  if (status !== undefined && status !== null && !STATUSES.includes(status)) {
    return refuse(`\`status\` must be one of: ${STATUSES.join(", ")}.`);
  }

  if (cursor !== undefined && cursor !== null && typeof cursor !== "string") {
    return refuse("`cursor` must be the string a previous page returned as next_cursor.");
  }

  if (limit !== undefined && limit !== null && !(Number.isInteger(limit) && limit > 0)) {
    return refuse("`limit` must be a positive integer (at most 100).");
  }

  const query = new URLSearchParams();
  if (typeof project_id === "string") query.set("project_id", project_id);
  if (typeof spec_id === "string") query.set("spec_id", spec_id);
  if (typeof status === "string") query.set("status", status);
  if (typeof cursor === "string" && cursor !== "") query.set("cursor", cursor);
  if (Number.isInteger(limit)) query.set("limit", String(limit));

  const qs = query.toString();
  // The path is written out, not `TUNING_DRAFTS_PATH`: the route sweep resolves a literal.
  return apiCall("GET", `/api/v1/tuning_drafts${qs ? `?${qs}` : ""}`, null);
}

/** `POST /api/v1/tuning_drafts/:id/landed` with `{pr_url}`. */
export async function tuningDraftMarkLanded({ draft_id, pr_url } = {}, { userKey, apiCall } = {}) {
  if (!userKey) return refuse(MISSING_USER_KEY);

  if (typeof draft_id !== "string" || !UUID.test(draft_id)) {
    return refuse("`draft_id` is required: the draft's UUID, from tuning_drafts.");
  }

  if (typeof pr_url !== "string" || pr_url.length > 500 || !PR_URL.test(pr_url)) {
    return refuse("`pr_url` is required: https://github.com/<owner>/<repo>/pull/<n>.");
  }

  return apiCall("POST", landedPath(draft_id), { pr_url });
}
