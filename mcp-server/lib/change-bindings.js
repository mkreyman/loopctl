/**
 * `change_binding_get` — `GET /api/v1/stories/:id/changes` (loopctl US-47.7, Epic 47).
 *
 * A story in a `chg`-mode repository is landed by the change protocol: chg-server delivers
 * the change's events to loopctl, and a `submitted` event binds the change to the story. This
 * is the read of that join — the session orchestrating the loop holds a story id and needs to
 * see which change implements it and how far that change has got.
 *
 * ## What the endpoint answers
 *
 * The story's bindings OLDEST FIRST (the current one is last), each with `repo`,
 * `change_id`, `current`, `superseded_at`, `submitter_not_claimant`, `inserted_at`, and its
 * change's APPLIED events in `event_seq` order (`event_seq`, `kind`, `revision`, `sha`,
 * `occurred_at`, `applied_at`). Both lists are bounded by the server and the bounds are in the
 * response's `meta`: a truncated list keeps the NEWEST entries, `binding_count` and each
 * binding's `applied_event_count` / `events_truncated` say when more exist. The event `data`
 * payload is not returned.
 *
 * ## Refusals
 *
 * - `404` — the story is not the caller's tenant's. Another tenant's id answers EXACTLY like
 *   an id nobody issued; that is the isolation working, not a lookup failure to retry.
 * - `401` — no key, or one that does not authenticate.
 * - `400` — a superadmin key without `X-Impersonate-Tenant`.
 * - `429` — rate limited.
 *
 * There is NO 403: the endpoint is `role: :agent` WITH the hierarchy, and every key role
 * (agent, orchestrator, user, superadmin) is at least that, so no key is refused for its role.
 *
 * A malformed id is refused HERE with `status: 0` (no request sent), for the reason
 * `delivery-loop.js`'s `uuid()` gives: the server would answer the same 404 as an unknown
 * story, and the two have opposite remedies.
 */

import { uuid } from "./delivery-loop.js";

export function storyChangesPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/changes`;
}

/** `GET /api/v1/stories/:id/changes`: the story's chg change bindings and applied events. */
export async function changeBindingGet({ story_id } = {}, { apiCall } = {}) {
  const bad = uuid(story_id, "story_id");
  if (bad) return bad;

  return apiCall("GET", storyChangesPath(story_id), null);
}
