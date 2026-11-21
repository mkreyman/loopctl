/**
 * `work_item_note` / `work_item_notes` (loopctl US-52.17): a work item's notes, the holder's
 * plan, progress, decisions and open questions, filed by section beside the story —
 * `POST` / `GET /api/v1/stories/:id/notes`.
 *
 * KEY: the session's own key (`agentKey()` in index.js — the holder credential once the
 * startup register succeeded, else LOOPCTL_AGENT_KEY). The write is accepted from the story's
 * CURRENT holder, so it must travel on the key that holds it: another session of the same
 * agent is refused 409 held_by_other_holder, like every claimant verb (US-52.14). An
 * orchestrator+ key may also write any item's note through the API; this tool does not send
 * one, because the session writing progress is the session holding the work.
 *
 * Section and body are checked here only for shape. The server owns the bounds
 * (`Loopctl.WorkItems.Note`: four sections, 1 to 16384 bytes, no credential-shaped body) and
 * answers 422 with the reason, so the two can never disagree.
 */

import { uuid } from "./delivery-loop.js";

export const NOTE_SECTIONS = ["plan", "progress", "decision", "question"];

function refuse(body) {
  return { error: true, status: 0, body };
}

export function notesPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/notes`;
}

/** `POST /api/v1/stories/:id/notes`: append one note. */
export async function writeWorkItemNote(
  { story_id, section, body, idempotency_key } = {},
  { apiCall } = {},
) {
  const bad = uuid(story_id, "story_id");
  if (bad) return bad;

  if (!NOTE_SECTIONS.includes(section)) {
    return refuse(`\`section\` is one of: ${NOTE_SECTIONS.join(", ")}.`);
  }

  if (typeof body !== "string" || body.trim() === "") {
    return refuse("`body` is required: the note's text.");
  }

  if (idempotency_key !== undefined && idempotency_key !== null && typeof idempotency_key !== "string") {
    return refuse("`idempotency_key` must be a string.");
  }

  const payload = { section, body };
  if (typeof idempotency_key === "string" && idempotency_key !== "") {
    payload.idempotency_key = idempotency_key;
  }

  return apiCall("POST", notesPath(story_id), payload);
}

/** `GET /api/v1/stories/:id/notes`: one page, oldest first, `current` on the first page. */
export async function listWorkItemNotes({ story_id, section, limit, after } = {}, { apiCall } = {}) {
  const bad = uuid(story_id, "story_id");
  if (bad) return bad;

  if (section !== undefined && section !== null && !NOTE_SECTIONS.includes(section)) {
    return refuse(`\`section\` is one of: ${NOTE_SECTIONS.join(", ")}.`);
  }

  if (limit !== undefined && limit !== null && !(Number.isInteger(limit) && limit > 0)) {
    return refuse("`limit` must be a positive integer (at most 200).");
  }

  if (after !== undefined && after !== null && typeof after !== "string") {
    return refuse("`after` must be the string a previous page returned as next_cursor.");
  }

  const query = new URLSearchParams();
  if (typeof section === "string") query.set("section", section);
  if (Number.isInteger(limit)) query.set("limit", String(limit));
  if (typeof after === "string" && after !== "") query.set("after", after);

  const qs = query.toString();
  return apiCall("GET", notesPath(story_id) + (qs ? `?${qs}` : ""), null);
}
