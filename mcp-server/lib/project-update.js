/**
 * `update_project`: the MCP half of `PATCH /api/v1/projects/:id` (`ProjectController.update`,
 * loopctl #1036). Without it no session could set a work project's `repo_url`, so SessionStart,
 * which resolves channels by `repo_url`, found no channel for that repo.
 *
 * WHAT THE ENDPOINT ACCEPTS: `name`, `slug`, `repo_url`, `description`, `tech_stack`,
 * `mission`, `metadata`. It drops every nil, so a request naming none is a 200 that changes
 * nothing: refused here. Only a kind: kb scope's `slug` can change, and its name follows it
 * (#1038); a work project's slug change is a 422. A body carrying `status` is a 422 (archive
 * and restore have their own routes), so it is never sent. An empty `mission` clears it.
 *
 * KEY: orchestrator role on a human-anchored tenant; index.js injects the orchestrator-pinned
 * `apiCall`, as it does for the epic writes.
 */

import { uuid as uuidRefusal } from "./delivery-loop.js";

export const PROJECT_UPDATABLE = [
  "name",
  "slug",
  "repo_url",
  "description",
  "tech_stack",
  "mission",
  "metadata",
];

export function projectPath(projectId) {
  return `/api/v1/projects/${encodeURIComponent(projectId)}`;
}

export async function updateProject(args = {}, { apiCall } = {}) {
  const refused = uuidRefusal(args.project_id, "project_id");
  if (refused) return refused;

  const body = {};
  for (const key of PROJECT_UPDATABLE) {
    if (args[key] != null) body[key] = args[key];
  }

  if (Object.keys(body).length === 0) {
    return {
      error: true,
      status: 0,
      body: `update_project needs at least one of ${PROJECT_UPDATABLE.join(", ")}; nothing was sent.`,
    };
  }

  return apiCall("PATCH", projectPath(args.project_id), body);
}
