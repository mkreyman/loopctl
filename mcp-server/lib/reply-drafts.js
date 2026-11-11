/**
 * `reply_draft_list` (loopctl US-48.9): the reply drafts loopctl stored for a project's support
 * tickets — `GET /api/v1/projects/:project_id/reply_drafts`.
 *
 * loopctl NEVER sends a draft. A runner session drafts a reply for a ticket triage rejected or
 * escalated, loopctl screens it and stores it, and a person reads it here and sends it
 * themselves, or does not. A `refused` draft carries the screen that refused it and no body.
 *
 * The endpoint is `role: :user` because the bodies are drafted from customer ticket text, so
 * this takes the EXACT user key, like the runner tools: a global LOOPCTL_API_KEY must not stand
 * in for it.
 *
 * `project_id` is not checked as a UUID here: the server resolves a project slug or repo name
 * to its id (#652), so any non-empty string is sent, path-encoded.
 */

export const MISSING_USER_KEY =
  "No user-role API key configured. Set LOOPCTL_USER_KEY to a user-role key to use " +
  "reply_draft_list: the drafts are written from customer ticket text, so the endpoint " +
  "refuses agent and orchestrator keys.";

function refuse(body) {
  return { error: true, status: 0, body };
}

export function replyDraftsPath(projectId) {
  return `/api/v1/projects/${encodeURIComponent(projectId)}/reply_drafts`;
}

/** `GET /api/v1/projects/:project_id/reply_drafts`, one page, newest first. */
export async function replyDraftList({ project_id, cursor, limit } = {}, { userKey, apiCall } = {}) {
  if (!userKey) return refuse(MISSING_USER_KEY);

  if (typeof project_id !== "string" || project_id.trim() === "") {
    return refuse("`project_id` is required (a project id, slug or repo name).");
  }

  if (cursor !== undefined && cursor !== null && typeof cursor !== "string") {
    return refuse("`cursor` must be the string a previous page returned as next_cursor.");
  }

  if (limit !== undefined && limit !== null && !(Number.isInteger(limit) && limit > 0)) {
    return refuse("`limit` must be a positive integer (at most 100).");
  }

  const query = new URLSearchParams();
  if (typeof cursor === "string" && cursor !== "") query.set("cursor", cursor);
  if (Number.isInteger(limit)) query.set("limit", String(limit));

  const qs = query.toString();
  return apiCall("GET", replyDraftsPath(project_id) + (qs ? `?${qs}` : ""), null);
}
