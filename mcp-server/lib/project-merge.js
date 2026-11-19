/**
 * `merge_project`: the MCP half of `POST /api/v1/projects/:id/merge_into`
 * (`ProjectController.merge_into`, US-52.2). It moves every row of one project into another
 * and archives the first, so a repo that grew two projects (a kb scope and a `-delivery` work
 * project) ends with one project and one channel.
 *
 * KEY: user role on a human-anchored tenant; index.js sends it with LOOPCTL_USER_KEY verbatim
 * when set, as delete_project does.
 */

import { uuid as uuidRefusal } from "./delivery-loop.js";

export function mergePath(projectId) {
  return `/api/v1/projects/${encodeURIComponent(projectId)}/merge_into`;
}

export async function mergeProject(args = {}, { apiCall } = {}) {
  const refused =
    uuidRefusal(args.project_id, "project_id") ??
    uuidRefusal(args.target_project_id, "target_project_id");
  if (refused) return refused;

  return apiCall("POST", mergePath(args.project_id), {
    target_project_id: args.target_project_id,
    dry_run: args.dry_run === true,
  });
}
