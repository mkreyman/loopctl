/**
 * Change threads (loopctl US-45.1, Epic 45): read a story's thread, record a checkpoint,
 * record an entry; and review on it (US-45.3): place a review, read its payload, record a
 * finding, a verdict or a fix.
 *
 * SINGLE SOURCE OF TRUTH. index.js injects `apiCall`; the unit suite runs this code with a
 * recording fake. Keys are selected here, from the injected env, so which key a call travels
 * on is testable behaviour:
 *
 * - thread_checkpoint travels on the key claim_story claims with: LOOPCTL_API_KEY when it is
 *   set, else LOOPCTL_AGENT_KEY (the same resolveKey order). The endpoint compares the key's
 *   agent with the story's claimant, so the checkpoint must go out on the key that claimed.
 * - thread_entry writes a `message` on the key named by `principal` (agent by default; a
 *   person writes on LOOPCTL_USER_KEY). Findings, fixes and verdicts have their own tools.
 * - thread_place_review travels on LOOPCTL_ORCH_KEY (or LOOPCTL_USER_KEY for principal user).
 * - thread_finding and thread_verdict travel ONLY on LOOPCTL_API_KEY: the key loopctl minted
 *   for the review dispatch, handed to the reviewer's session as its one key.
 * - thread_fix travels on the key claim_story claims with, as thread_checkpoint does.
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

// The key claim_story claimed with (index.js resolveKey: LOOPCTL_API_KEY first), so a
// checkpoint or an agent-principal entry is sent as the same agent that holds the claim.
function claimKeyVar(env) {
  return env.LOOPCTL_API_KEY ? "LOOPCTL_API_KEY" : "LOOPCTL_AGENT_KEY";
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
    env[claimKeyVar(env)],
    claimKeyVar(env),
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

  const keyVar = principal === "agent" ? claimKeyVar(env) : PRINCIPAL_KEYS[principal];
  if (!PRINCIPAL_KEYS[principal]) {
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

// --- US-45.3: review on the thread ------------------------------------------------------

export function reviewsPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/thread/reviews`;
}

export function reviewPath(storyId, reviewId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/thread/reviews/${encodeURIComponent(reviewId)}`;
}

export function findingsPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/thread/findings`;
}

export function verdictsPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/thread/verdicts`;
}

export function fixesPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/thread/fixes`;
}

// A review dispatch's findings and verdict travel ONLY on LOOPCTL_API_KEY, the one key a
// dispatched session is given, and never fall back to LOOPCTL_AGENT_KEY: that is usually an
// implementer's key, and a process must never hold both (loopctl CLAUDE.md).
const REVIEW_KEY_VAR = "LOOPCTL_API_KEY";

/** `POST /api/v1/stories/:id/thread/reviews` on the orchestrator key (or the user key). */
export async function placeReview(
  { story_id, agent_id, checkpoint_id, expires_in_seconds, principal = "orchestrator" } = {},
  { apiCall, env = process.env } = {},
) {
  if (!present(story_id)) return missing("story_id");
  if (!present(agent_id)) return missing("agent_id");
  if (principal !== "orchestrator" && principal !== "user") {
    return { error: true, status: 0, body: "`principal` must be orchestrator or user." };
  }

  const keyVar = PRINCIPAL_KEYS[principal];
  return apiCall(
    "POST",
    reviewsPath(story_id),
    compact({ agent_id, checkpoint_id, expires_in_seconds }),
    env[keyVar],
    keyVar,
  );
}

/** `GET /api/v1/stories/:id/thread/reviews/:review_id` on the first key configured. */
export async function getReview({ story_id, review_id } = {}, { apiCall, env = process.env } = {}) {
  if (!present(story_id)) return missing("story_id");
  if (!present(review_id)) return missing("review_id");
  const keyVar =
    ["LOOPCTL_API_KEY", "LOOPCTL_AGENT_KEY", "LOOPCTL_ORCH_KEY", "LOOPCTL_USER_KEY"].find(
      (name) => env[name],
    ) || REVIEW_KEY_VAR;
  return apiCall("GET", reviewPath(story_id, review_id), null, env[keyVar], keyVar);
}

/** `POST /api/v1/stories/:id/thread/findings` on the review dispatch's key. */
export async function recordFinding(
  { story_id, idempotency_key, body, severity, location, introduced_by } = {},
  { apiCall, env = process.env } = {},
) {
  if (!present(story_id)) return missing("story_id");
  if (!present(idempotency_key)) return missing("idempotency_key");
  if (!present(body)) return missing("body");
  if (!present(severity)) return missing("severity");

  return apiCall(
    "POST",
    findingsPath(story_id),
    compact({ idempotency_key, body, severity, location, introduced_by }),
    env[REVIEW_KEY_VAR],
    REVIEW_KEY_VAR,
  );
}

/** `POST /api/v1/stories/:id/thread/verdicts` on the review dispatch's key. */
export async function recordVerdict(
  { story_id, idempotency_key, body } = {},
  { apiCall, env = process.env } = {},
) {
  if (!present(story_id)) return missing("story_id");
  if (!present(idempotency_key)) return missing("idempotency_key");
  if (!present(body)) return missing("body");

  return apiCall(
    "POST",
    verdictsPath(story_id),
    { idempotency_key, body },
    env[REVIEW_KEY_VAR],
    REVIEW_KEY_VAR,
  );
}

/** `POST /api/v1/stories/:id/thread/fixes` on the key claim_story claims with. */
export async function recordFix(
  { story_id, claim_epoch, checkpoint_id, finding_ids, idempotency_key, body } = {},
  { apiCall, env = process.env } = {},
) {
  if (!present(story_id)) return missing("story_id");
  if (!present(checkpoint_id)) return missing("checkpoint_id");
  if (!present(idempotency_key)) return missing("idempotency_key");
  if (!present(body)) return missing("body");
  if (!Array.isArray(finding_ids) || finding_ids.length === 0) {
    return { error: true, status: 0, body: "`finding_ids` must name at least one finding." };
  }
  if (!Number.isInteger(claim_epoch) || claim_epoch < 0) {
    return {
      error: true,
      status: 0,
      body: "`claim_epoch` is required: the non-negative integer your claim returned.",
    };
  }

  return apiCall(
    "POST",
    fixesPath(story_id),
    { claim_epoch, checkpoint_id, finding_ids, idempotency_key, body },
    env[claimKeyVar(env)],
    claimKeyVar(env),
  );
}
