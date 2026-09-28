/**
 * The epics surface — `list_epics`, `create_epic`, `get_epic`, `update_epic`, `delete_epic`
 * and `epic_progress` — the MCP half of the six `EpicController` routes (loopctl #876).
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
 *     nil, so a field cannot be nulled through it, and a request naming none of them is a
 *     200 that changes nothing. That shape is refused here, as `update_story` refuses it.
 *     `metadata` is REPLACED whole, never merged.
 *   - index pages (`page`, `page_size`) and filters by `phase`.
 *
 * KEYS, from the controller's plugs: reads are `role: :agent` (any key); create and update
 * are `role: :orchestrator` with the hierarchy, and human-anchored; delete is `role: :user`,
 * human-anchored, and CASCADES to the epic's stories.
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const UPDATABLE = ["title", "description", "phase", "position", "metadata"];

function refuse(body) {
  return { error: true, status: 0, body };
}

// A malformed id is refused locally rather than sent: the server's 404 for it reads the same
// as "no such epic in your tenant". The value is not echoed, since a tool result lands in the
// transcript and a malformed id is often something pasted into the wrong argument.
function badId(name, value) {
  if (typeof value !== "string" || value.trim() === "") {
    return refuse(`\`${name}\` is required.`);
  }

  if (!UUID_RE.test(value)) {
    return refuse(`\`${name}\` must be a UUID; the value given is not one.`);
  }

  return null;
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
  if (page !== undefined) params.set("page", String(page));
  if (page_size !== undefined) params.set("page_size", String(page_size));
  if (phase !== undefined) params.set("phase", String(phase));
  const query = params.toString();
  return query === "" ? "" : `?${query}`;
}

export async function listEpics({ project_id, page, page_size, phase } = {}, { apiCall } = {}) {
  return (
    badId("project_id", project_id) ??
    apiCall("GET", projectEpicsPath(project_id, { page, page_size, phase }))
  );
}

export async function createEpic(
  { project_id, number, title, description, phase, position, metadata } = {},
  { apiCall } = {},
) {
  const refused = badId("project_id", project_id);
  if (refused) return refused;

  if (!Number.isInteger(number)) {
    return refuse("`number` is required and must be an integer; it cannot change later.");
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

  const body = {};
  for (const field of UPDATABLE) {
    if (args[field] !== undefined && args[field] !== null) body[field] = args[field];
  }

  if (Object.keys(body).length === 0) {
    return refuse(
      `Name at least one of ${UPDATABLE.join(", ")}: the endpoint drops every absent or null ` +
        "field, so a request with none of them answers 200 and changes nothing.",
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
