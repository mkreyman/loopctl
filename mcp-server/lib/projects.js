/**
 * `update_project` — the MCP half of `PATCH /api/v1/projects/:id` (`ProjectController.update`).
 *
 * WHY IT EXISTS. `delete_project` ARCHIVES a project, and the only way back for a WORK project
 * is this PATCH with `status: "active"`; until this tool, no session could reach it, so an
 * archive was one-way in practice (a kb scope has its own way back, `restore_kb_scope`).
 *
 * WHAT THE ENDPOINT ACCEPTS, read from `lib/loopctl_web/controllers/project_controller.ex`:
 * `name`, `repo_url`, `description`, `tech_stack`, `status`, `mission`, `metadata`. It DROPS
 * every nil, so a null writes nothing and a request naming none of them is a 200 that changes
 * nothing; both are refused here, as `update_epic` refuses them. An empty string clears a
 * text field (a blank `name` is a 422). `metadata` is REPLACED whole, never merged.
 *
 * `status` is checked HERE because the controller maps an unknown value to nil and then drops
 * it (`safe_to_status/1`): `status: "actve"` would answer 200 with the project still archived,
 * the exact failure a restore must not hide.
 *
 * KEYS, from the controller's plugs: `role: :orchestrator` with the hierarchy, and
 * human-anchored (`RequireHumanAnchor` on `:update`), so an agent-rooted tenant is 403
 * `custody_tier_required`. `kind` and `slug` are not in the update cast, so neither changes.
 */

import { uuid as uuidRefusal } from "./delivery-loop.js";
import { namedBody } from "./story-update.js";

export const UPDATABLE = [
  "name",
  "repo_url",
  "description",
  "tech_stack",
  "status",
  "mission",
  "metadata",
];

export const STATUSES = ["active", "archived"];

function refuse(body) {
  return { error: true, status: 0, body };
}

// One template literal, the shape `test/tool-surface.js` resolves to the route it names.
export function projectPath(projectId) {
  return `/api/v1/projects/${projectId}`;
}

export async function updateProject(args = {}, { apiCall } = {}) {
  const refused = uuidRefusal(args.project_id, "project_id");
  if (refused) return refused;

  const { body, error } = namedBody(
    args,
    UPDATABLE,
    'To clear `repo_url`, `description`, `tech_stack` or `mission`, send an empty string ("").',
  );
  if (error) return refuse(error);

  if (Object.keys(body).length === 0) {
    return refuse(
      `Name at least one of ${UPDATABLE.join(", ")}: the endpoint drops every absent field, ` +
        "so a request with none of them answers 200 and changes nothing.",
    );
  }

  if ("status" in body && !STATUSES.includes(body.status)) {
    return refuse(
      `\`status\` must be one of ${STATUSES.join(", ")}. The endpoint silently drops any other ` +
        "value and answers 200, so it is refused here rather than reported as a change.",
    );
  }

  return apiCall("PATCH", projectPath(args.project_id), body);
}
