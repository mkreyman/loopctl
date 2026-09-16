/**
 * `update_story` — `PATCH /api/v1/stories/:id` (loopctl #846.6).
 *
 * WHY IT EXISTS. The endpoint has been served since before this package's write surface was
 * built (`lib/loopctl_web/router.ex:477`, `StoryController, :update`) and no MCP tool reached
 * it, so a session that filed a story and then found its own severity wrong could not correct
 * it. `create_story`, `import_stories` and `backfill_story` were the whole write surface;
 * `import_stories` with `merge: true` posts a WHOLE EPIC payload, so correcting one field
 * means resending every sibling and risking them. That is the rule in loopctl's CLAUDE.md —
 * an operator-facing endpoint is not done until an MCP tool calls it — failing for the third
 * time on one workflow.
 *
 * WHAT THE ENDPOINT ACTUALLY ACCEPTS, read rather than assumed. `StoryController.update/2`
 * (`lib/loopctl_web/controllers/story_controller.ex:429-455`) builds its attrs from exactly
 * five params — `title`, `description`, `acceptance_criteria`, `estimated_hours`, `metadata`
 * (`:434-440`) — and then DROPS every nil (`Map.reject`, `:443`). `Story.update_changeset/2`
 * casts the same five (`lib/loopctl/work_breakdown/story.ex:189-195`). Nothing else on a story
 * is reachable here: `number` cannot change after creation, and the two status fields have
 * their own custody endpoints.
 *
 * THREE CONSEQUENCES OF THAT `Map.reject`, all of them things a caller would otherwise learn
 * from a 200 that changed nothing:
 *
 *   1. A field cannot be NULLED through this endpoint. `description: null` is dropped before
 *      the changeset sees it, so it is a no-op and not an erase.
 *   2. An UNPARSEABLE `estimated_hours` is silently ignored: `parse_decimal/1`
 *      (`story_controller.ex:530-538`) answers nil for a string `Decimal.parse/1` rejects, and
 *      nil is then dropped. The request answers 200 with the old value. That is the one shape
 *      refused locally below — the same reasoning as the UUID check in `lib/delivery-loop.js`:
 *      the server's answer cannot be told apart from success, and a client check can.
 *   3. A request naming NO updatable field is a 200 that writes an audit entry and changes
 *      nothing (`Stories.update_story/4` logs `action: "updated"` unconditionally,
 *      `lib/loopctl/work_breakdown/stories.ex:213-249`). Refused here.
 *
 * ## `metadata` IS REPLACED WHOLE, AND THAT IS THE HAZARD THIS TOOL MUST ANNOUNCE
 *
 * `metadata` is an ordinary `:map` field (`story.ex:84`) in the cast list above, so the map
 * sent REPLACES the stored one — there is no merge anywhere on this path. A caller sending
 * `{"severity": "high"}` to a story whose metadata holds six keys keeps one and loses five,
 * and the response is a 200.
 *
 * That is not merely lossy, it is the laundering hazard loopctl's CLAUDE.md documents. The
 * story field `lifecycle_entered_at` — the marker that says a story once entered the lifecycle,
 * and therefore may not be backfilled straight to `verified` — lived in `metadata` first, and
 * one ordinary PATCH erased it, restoring the claim -> force-unclaim -> backfill-to-verified
 * launder. It is a COLUMN now (`story.ex:102`) precisely so that no changeset casts it, and
 * the comment above it (`story.ex:95-101`) says never to add it to a cast list. Both halves
 * check out: it is absent from `update_changeset/2`'s cast list above, and from
 * `changeset/2`'s. So this endpoint can no longer erase THAT marker — and a partial `metadata`
 * send still silently drops every other key, which is why the tool description leads with
 * "read the story first, then send the whole map".
 *
 * ## KEY
 *
 * ORCHESTRATOR, with the hierarchy applying: the action is mounted `role: :orchestrator`
 * (`story_controller.ex:29-30`), NOT `exact_role:`, so `RequireRole` admits a `:user` or
 * `:superadmin` key too (`require_role.ex`'s hierarchy clause). Nothing is pinned here for
 * that reason — `LOOPCTL_ORCH_KEY` is passed as an ordinary override, so a global
 * `LOOPCTL_API_KEY` of any sufficient role still wins, exactly as it does for `create_story`
 * and `backfill_story`. The tenant must also be human-anchored (`RequireHumanAnchor`,
 * `story_controller.ex:35-36`): an agent-rooted tenant is refused 403 `custody_tier_required`.
 *
 * ## `story_id` IS SHAPE-CHECKED, ON THE SHARED GUARD AND NOT A SECOND COPY
 *
 * This tool shipped without one while all four verbs in `lib/delivery-loop.js` had it, and the
 * omission made this file's own tool description false: it promises "404 for an unknown story"
 * as that status's only meaning. A malformed id gets the SAME 404.
 * `StoryController.update/2` reaches `Stories.get_story/2`
 * (`lib/loopctl/work_breakdown/stories.ex:185-190`), whose `AdminRepo.get_by(Story, id:
 * story_id, …)` puts the value into a `where` against a `:binary_id` column with no cast; the
 * `Ecto.Query.CastError` that raises is mapped to 404 by loopctl's deliberate backstop
 * (`lib/loopctl_web/plugs/cast_error_handler.ex:32-35`), and the body is
 * `LoopctlWeb.ErrorJSON`'s generic `{"error": {"status": 404, "message": "Not found"}}` — byte
 * for byte what `FallbackController` answers for a well-formed id naming no story
 * (`lib/loopctl_web/fallback_controller.ex:74-78`). Two opposite remedies, one answer.
 *
 * The check is `uuid()`, IMPORTED from `lib/delivery-loop.js` rather than reimplemented, so the
 * refusal a caller reads for a bad `story_id` does not depend on which tool they reached for.
 * Its reasoning — why the refusal carries `status: 0` and never echoes the value — is the long
 * comment over it there, and it is not restated here.
 */

import { uuid as uuidRefusal } from "./delivery-loop.js";

const UPDATABLE = ["title", "description", "acceptance_criteria", "estimated_hours", "metadata"];

function refuse(body) {
  return { error: true, status: 0, body };
}

export function storyPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}`;
}

/**
 * Build the PATCH body from the fields the caller actually named.
 *
 * `undefined` means "not named" and is omitted. `null` is NOT silently omitted: it is refused,
 * because a caller writing it means to clear the field and the server would answer 200 having
 * dropped it (`Map.reject`, `story_controller.ex:443`).
 */
export function updateBody(args = {}) {
  const body = {};

  for (const field of UPDATABLE) {
    const value = args[field];
    if (value === undefined) continue;
    if (value === null) {
      return {
        error: `\`${field}\` cannot be set to null through this endpoint. The controller drops ` +
          `every nil before the changeset sees it, so the request would answer 200 with the ` +
          `field unchanged. Send the value you want, or leave the field out.`,
      };
    }
    body[field] = value;
  }

  return { body };
}

/**
 * `PATCH /api/v1/stories/:id` — correct a filed story's title, description, acceptance
 * criteria, estimate or metadata.
 */
export async function updateStory(args = {}, { apiCall } = {}) {
  const bad = uuidRefusal(args.story_id, "story_id");
  if (bad) return bad;

  const { story_id } = args;

  const { body, error } = updateBody(args);
  if (error) return refuse(error);

  if (Object.keys(body).length === 0) {
    return refuse(
      "Nothing to update. Name at least one of: " +
        UPDATABLE.join(", ") +
        ". A request carrying none of them is a 200 that changes nothing and still writes an " +
        "audit entry.",
    );
  }

  if (body.estimated_hours !== undefined && !numeric(body.estimated_hours)) {
    return refuse(
      "`estimated_hours` must be a number, or a string a decimal parser accepts. loopctl " +
        "parses it with Decimal.parse/1 and DROPS the field when that fails, so an " +
        "unparseable value answers 200 with the estimate unchanged — indistinguishable from " +
        "success.",
    );
  }

  if (body.metadata !== undefined && !plainObject(body.metadata)) {
    return refuse(
      "`metadata` must be an object. The server validates the same thing and answers 422 " +
        "(`must be a map`); refusing here says so without a round trip.",
    );
  }

  return apiCall("PATCH", storyPath(story_id), body);
}

function numeric(value) {
  if (typeof value === "number") return Number.isFinite(value);
  if (typeof value !== "string") return false;
  return /^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$/.test(value.trim());
}

function plainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
