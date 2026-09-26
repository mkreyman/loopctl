/**
 * Change threads (loopctl US-45.1, Epic 45): read a story's thread, record a checkpoint,
 * record an entry.
 *
 * SINGLE SOURCE OF TRUTH. index.js injects `apiCall`; the unit suite runs this code with a
 * recording fake. Keys are selected here, from the injected env, so which key a call travels
 * on is testable behaviour:
 *
 * - thread_checkpoint travels on the AGENT key. The endpoint is `exact_role: :agent` and
 *   compares the key's agent with the story's claimant: only the claimant says a commit is
 *   part of the thread.
 * - thread_entry writes a `message` or `review_requested` on the key named by `principal`
 *   (agent by default; a person writes on LOOPCTL_USER_KEY). Findings, fixes and verdicts
 *   are not written through this tool: their author is a review dispatch (loopctl US-45.3).
 * - thread_get reads on the first key configured, agent first, then LOOPCTL_API_KEY, the
 *   orchestrator key and the user key: reads are open to every role.
 *
 * Every call passes the env var it is pinned to as `keyHint`, so a missing key is reported
 * by name rather than as some other feature's configuration error.
 *
 * Only presence of the required fields is checked here. Everything else is the server's
 * judgement and passes through unchanged.
 */

const PRINCIPAL_KEYS = {
  agent: "LOOPCTL_AGENT_KEY",
  orchestrator: "LOOPCTL_ORCH_KEY",
  user: "LOOPCTL_USER_KEY",
};

// One literal template per route, so `test/tool-surface.js` resolves each call site to the
// route it sends (a path built from a suffix argument reads as no route at all).
export function threadPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/thread`;
}

export function checkpointsPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/thread/checkpoints`;
}

export function entriesPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/thread/entries`;
}

function missing(field) {
  return { error: true, status: 0, body: `\`${field}\` is required.` };
}

function present(value) {
  return typeof value === "string" && value.trim() !== "";
}

// Drops keys whose value is undefined or null, so an absent optional is not sent as null.
function compact(obj) {
  return Object.fromEntries(
    Object.entries(obj).filter(([, v]) => v !== undefined && v !== null),
  );
}

/** `GET /api/v1/stories/:id/thread`. */
export async function getThread({ story_id, after_seq, limit } = {}, { apiCall, env = process.env } = {}) {
  if (!present(story_id)) return missing("story_id");
  const keyVar =
    ["LOOPCTL_AGENT_KEY", "LOOPCTL_API_KEY", "LOOPCTL_ORCH_KEY", "LOOPCTL_USER_KEY"].find(
      (name) => env[name],
    ) || "LOOPCTL_AGENT_KEY";
  const query = compact({ after_seq, limit });
  const qs = new URLSearchParams(query).toString();
  return apiCall(
    "GET",
    qs ? `${threadPath(story_id)}?${qs}` : threadPath(story_id),
    null,
    env[keyVar],
    keyVar,
  );
}

/** `POST /api/v1/stories/:id/thread/checkpoints` on the AGENT key. */
export async function recordCheckpoint(
  { story_id, claim_epoch, commit_sha, tree_sha, note } = {},
  { apiCall, env = process.env } = {},
) {
  if (!present(story_id)) return missing("story_id");
  if (!present(commit_sha)) return missing("commit_sha");
  if (!present(tree_sha)) return missing("tree_sha");
  if (!Number.isInteger(claim_epoch) || claim_epoch < 0) {
    return {
      error: true,
      status: 0,
      body: "`claim_epoch` is required: the non-negative integer your claim returned.",
    };
  }

  return apiCall(
    "POST",
    checkpointsPath(story_id),
    compact({ claim_epoch, commit_sha, tree_sha, note }),
    env.LOOPCTL_AGENT_KEY,
    "LOOPCTL_AGENT_KEY",
  );
}

/** `POST /api/v1/stories/:id/thread/entries` on the key `principal` names. */
export async function recordEntry(
  {
    story_id,
    kind,
    idempotency_key,
    body,
    checkpoint_id,
    principal = "agent",
  } = {},
  { apiCall, env = process.env } = {},
) {
  if (!present(story_id)) return missing("story_id");
  if (!present(kind)) return missing("kind");
  if (!present(idempotency_key)) return missing("idempotency_key");
  if (!present(body)) return missing("body");

  const keyVar = PRINCIPAL_KEYS[principal];
  if (!keyVar) {
    return {
      error: true,
      status: 0,
      body: "`principal` must be one of agent, orchestrator, user.",
    };
  }

  return apiCall(
    "POST",
    entriesPath(story_id),
    compact({ kind, idempotency_key, body, checkpoint_id }),
    env[keyVar],
    keyVar,
  );
}
