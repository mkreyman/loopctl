/**
 * The epics surface — `list_epics`, `create_epic`, `get_epic`, `update_epic`, `delete_epic`
 * and `epic_progress` — the MCP half of the `EpicController` routes (loopctl #876).
 *
 * WHY IT EXISTS. The routes were served and no tool reached them, so a session could create
 * an epic through `import_stories` and then not name it: import answers COUNTS
 * (`epics_created: 1`), never ids. Enrolling an intake source needs a `target_epic_id`, and
 * the only way to learn one was to create a throwaway story in the epic and read `epic_id`
 * back off `list_stories`. `import_stories` was not widened to return ids instead: an epic
 * also has to be listed, read, corrected and measured after it exists, which a create
 * response cannot do, so the tools cover the whole surface.
 *
 * WHAT THE ENDPOINTS ACCEPT, read from `lib/loopctl_web/controllers/epic_controller.ex`:
 *
 *   - create casts `number`, `title`, `description`, `phase`, `position` (default 0) and
 *     `metadata` (default {}); `number` is required and cannot change afterwards.
 *   - update takes `title`, `description`, `phase`, `position`, `metadata` and DROPS every
 *     nil, so a null writes nothing, and a request naming none of them is a 200 that changes
 *     nothing. Both shapes are refused here, as `update_story` refuses them. An empty string
 *     is what CLEARS `description` or `phase` (a blank `title` is a 422). `metadata` is
 *     REPLACED whole, never merged.
 *   - index pages (`page`, `page_size`) and filters by `phase`.
 *
 * KEYS, from the controller's plugs: reads are `role: :agent` (any key); create and update
 * are `role: :orchestrator` with the hierarchy, and human-anchored; delete is `role: :user`,
 * human-anchored, and CASCADES to the epic's stories — refused 422 when a dispatch, capability
 * token or verification run references a story in it (those do not cascade) or an active
 * intake source targets the epic. `delete_story` is `lib/story-update.js`'s.
 */

import { uuid as uuidRefusal } from "./delivery-loop.js";
import { namedBody } from "./story-update.js";

const UPDATABLE = ["title", "description", "phase", "position", "metadata"];

function refuse(body) {
  return { error: true, status: 0, body };
}

// A malformed id is refused locally rather than sent, through the SAME guard the other tools
// use (`lib/delivery-loop.js`'s `uuid`), so a bad id reads the same whichever tool it reached.
function badId(name, value) {
  return uuidRefusal(value, name);
}

// Each builder is ONE template literal, which is the shape `test/tool-surface.js` resolves to
// the route it names: the query string after `/epics` contributes nothing to the route.
export function projectEpicsPath(projectId, query = {}) {
  return `/api/v1/projects/${encodeURIComponent(projectId)}/epics${epicsQuery(query)}`;
}

export function epicPath(epicId) {
  return `/api/v1/epics/${encodeURIComponent(epicId)}`;
}

export function epicProgressPath(epicId) {
  return `/api/v1/epics/${encodeURIComponent(epicId)}/progress`;
}

function epicsQuery({ page, page_size, phase } = {}) {
  const params = new URLSearchParams();
  // `!= null`, not `!== undefined`: a client sending an optional argument as null means
  // "not named", and `phase=null` would filter on the literal phase "null".
  if (page != null) params.set("page", String(page));
  if (page_size != null) params.set("page_size", String(page_size));
  if (phase != null) params.set("phase", String(phase));
  const query = params.toString();
  return query === "" ? "" : `?${query}`;
}

export async function listEpics({ project_id, page, page_size, phase } = {}, { apiCall } = {}) {
  const refused = badId("project_id", project_id);
  if (refused) return refused;

  // A cleared phase is stored as NULL, so `phase=` would filter on the empty string and match
  // nothing: an empty list that reads as "no epics". Refused rather than answered wrongly.
  if (phase === "") {
    return refuse(
      "`phase` cannot be empty: no filter selects epics without a phase. Leave it out to list " +
        "every epic.",
    );
  }

  return apiCall("GET", projectEpicsPath(project_id, { page, page_size, phase }));
}

export async function createEpic(
  { project_id, number, title, description, phase, position, metadata } = {},
  { apiCall } = {},
) {
  const refused = badId("project_id", project_id);
  if (refused) return refused;

  // An integer, as the input schema declares, and at least 1, which the server requires.
  if (!Number.isInteger(number) || number < 1) {
    return refuse("`number` is required and must be an integer of at least 1; it is fixed for good.");
  }

  if (typeof title !== "string" || title.trim() === "") {
    return refuse("`title` is required.");
  }

  const body = { number, title };
  if (description !== undefined) body.description = description;
  if (phase !== undefined) body.phase = phase;
  if (position !== undefined) body.position = position;
  if (metadata !== undefined) body.metadata = metadata;

  return apiCall("POST", projectEpicsPath(project_id), body);
}

export async function getEpic({ epic_id } = {}, { apiCall } = {}) {
  return badId("epic_id", epic_id) ?? apiCall("GET", epicPath(epic_id));
}

export async function updateEpic(args = {}, { apiCall } = {}) {
  const refused = badId("epic_id", args.epic_id);
  if (refused) return refused;

  // A null is refused, as `update_story` refuses it (`namedBody`). An EMPTY string is what
  // clears a field: it survives the controller's nil filter and the changeset casts it to nil,
  // so `description: ""` or `phase: ""` erases it (a blank `title` is a 422).
  const { body, error } = namedBody(
    args,
    UPDATABLE,
    'To clear `description` or `phase`, send an empty string ("").',
  );
  if (error) return refuse(error);

  if (Object.keys(body).length === 0) {
    return refuse(
      `Name at least one of ${UPDATABLE.join(", ")}: the endpoint drops every absent field, ` +
        "so a request with none of them answers 200 and changes nothing.",
    );
  }

  return apiCall("PATCH", epicPath(args.epic_id), body);
}

export async function deleteEpic({ epic_id } = {}, { apiCall } = {}) {
  return badId("epic_id", epic_id) ?? apiCall("DELETE", epicPath(epic_id), null);
}

export async function epicProgress({ epic_id } = {}, { apiCall } = {}) {
  return badId("epic_id", epic_id) ?? apiCall("GET", epicProgressPath(epic_id));
}

// The key an epic WRITE travels on: `role: :orchestrator` WITH the hierarchy
// (epic_controller.ex), so a user key passes too. The first of LOOPCTL_ORCH_KEY and
// LOOPCTL_USER_KEY that is set is named, to be sent VERBATIM; `null` when neither is, and the
// caller's default key selection applies.
export function epicWriteKeyHint(env = process.env) {
  if (env.LOOPCTL_ORCH_KEY) return "LOOPCTL_ORCH_KEY";
  if (env.LOOPCTL_USER_KEY) return "LOOPCTL_USER_KEY";
  return null;
}

// The key a DELETE travels on: LOOPCTL_USER_KEY, sent VERBATIM when it is set, so a global
// LOOPCTL_API_KEY of a lesser role cannot displace it; `null` when it is not, and the caller's
// default selection applies. `role: :user` WITH the hierarchy, so the global key may well pass.
export function deleteKeyHint(env = process.env) {
  return env.LOOPCTL_USER_KEY ? "LOOPCTL_USER_KEY" : null;
}
