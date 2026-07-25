/**
 * One-call handoff composition (loopctl issue #528, follow-up to #517).
 *
 * WHY THIS EXISTS. #518 fixed the AUTHORIZATION crux behind #517 — an agent-role key
 * can now post to a `kind: kb` channel in its own tenant, so the coordination bus is
 * reachable for a repo with no work project. It did not fix the AFFORDANCE: creating a
 * handoff for a brand-new repo was still `resolve_project` -> (404) -> `create_kb_scope`
 * -> `channel_post`, with the `handoff:<anchor>` key convention documented only at the
 * tail of `channel_post`'s description. #517 is the evidence that a path documented
 * across six tools is not a discoverable path. `createHandoff` collapses the SENDER
 * flow into one call.
 *
 * The receiver flow is deliberately NOT wrapped: `channel_handoffs` -> `channel_claim`
 * -> `channel_done` is already one obvious call per step, and each is a distinct
 * decision the agent must make explicitly (claiming is the anti-double-work gate).
 *
 * SINGLE SOURCE OF TRUTH. All composition/derivation logic lives here so the unit
 * suite exercises the code the server ships (the repo convention — see
 * lib/http-helpers.js). The three HTTP calls are INJECTED (`deps`), so every branch
 * below is testable with fakes and no network.
 *
 * NEVER attempts `create_project`. A work project is human-anchor-gated by design
 * (#505); trying it first is exactly the dead-end #517 hit, and its 403 reads as a wall
 * rather than a redirect.
 */

export const HANDOFF_KEY_PREFIX = "handoff:";

// Mirrors Loopctl.Coordination.ChannelPost's @key_max_length
// (lib/loopctl/coordination/channel_post.ex:98). Validated HERE so an over-long anchor
// gets a specific, actionable client error instead of a server 422 the agent has to
// reverse-engineer.
export const KEY_MAX_BYTES = 200;

// Mirrors Loopctl.Projects.Project's slug rules (lib/loopctl/projects/project.ex:31,137):
// /^[a-z0-9][a-z0-9-]*[a-z0-9]$/, 2..63 chars. A derived slug that cannot satisfy these
// is reported as underivable rather than sent on to fail server-side.
export const SLUG_MIN_LENGTH = 2;
export const SLUG_MAX_LENGTH = 63;

function byteLength(value) {
  return Buffer.byteLength(value, "utf8");
}

// Codepoint check rather than a regex literal: NUL and C0/DEL control characters are
// rejected server-side, and writing the range as an escape-laden regex is exactly the
// kind of literal that gets mangled in transit. 0x00-0x1f plus 0x7f.
function hasControlChars(value) {
  for (const char of value) {
    const code = char.codePointAt(0);
    if (code < 0x20 || code === 0x7f) return true;
  }
  return false;
}

/**
 * Shape a failure the way `apiCall` does (`{ error: true, status, body }`) so
 * `toContent` flags it as an MCP error, plus a `stage` naming WHICH step failed
 * (validate | resolve | create_channel | post). The stage is the whole point: "422 on
 * post" and "422 on create" send an agent to completely different places, and #517's
 * core complaint was an error that pointed nowhere.
 */
function failure(stage, status, body, extra = {}) {
  return { error: true, stage, status, body, ...extra };
}

/**
 * Build the channel key for a handoff anchor.
 *
 * Idempotent on the prefix: an agent that passes "handoff:repo#812" gets that key back
 * unchanged rather than "handoff:handoff:repo#812". Returns `{ key, anchor }` or
 * `{ error }`.
 */
export function handoffKey(anchor) {
  if (typeof anchor !== "string" || !anchor.trim()) {
    return {
      error:
        "anchor is required: a stable, durable id for this handoff (e.g. " +
        "'home_care_billing#812' or 'claude-harness-kit:review-vs-goal'). It becomes the " +
        "channel key 'handoff:<anchor>', which is what makes the handoff discoverable to " +
        "channel_handoffs, claimable via channel_claim, and idempotent on retry.",
    };
  }

  const trimmed = anchor.trim();

  // NUL and control characters are rejected server-side; catch them here so the message
  // names the offending field.
  if (hasControlChars(trimmed)) {
    return { error: "anchor must not contain control characters or NUL bytes." };
  }

  const key = trimmed.startsWith(HANDOFF_KEY_PREFIX)
    ? trimmed
    : `${HANDOFF_KEY_PREFIX}${trimmed}`;

  if (byteLength(key) > KEY_MAX_BYTES) {
    return {
      error:
        `anchor is too long: the channel key '${HANDOFF_KEY_PREFIX}<anchor>' must be at ` +
        `most ${KEY_MAX_BYTES} bytes (this one is ${byteLength(key)}). Use a short stable ` +
        "id (repo#issue) and put the detail in the durable home.",
    };
  }

  return { key, anchor: key.slice(HANDOFF_KEY_PREFIX.length) };
}

/**
 * The repo basename from a git remote URL or a bare owner/repo, with original casing
 * preserved (so it can seed a human-readable scope NAME).
 *
 * Handles: git@github.com:owner/repo.git, https://github.com/owner/repo(/),
 * ssh://git@host/owner/repo.git, bare owner/repo, and trailing query/fragment.
 */
export function repoBasename(repoUrl) {
  if (typeof repoUrl !== "string") return null;

  let value = repoUrl.trim();
  if (!value) return null;

  value = value.split(/[?#]/)[0]; // drop any query/fragment
  value = value.replace(/\/+$/, ""); // drop trailing slashes
  value = value.replace(/\.git$/i, ""); // drop the .git suffix

  // Split on both / and : so the scp-style git@host:owner/repo form yields "repo".
  const segments = value.split(/[/:]/).filter(Boolean);
  const basename = segments.pop();
  return basename || null;
}

/**
 * Derive a server-valid project slug from a repo URL.
 *
 * DETERMINISM IS THE POINT (#528 AC4): the created scope must be re-resolvable by the
 * same derivation on a retry, or a repeated handoff would create a second scope and burn
 * the tenant's max_projects budget. Underscores become hyphens, matching the existing
 * convention in this tenant (repo home_care_billing -> slug home-care-billing).
 *
 * Returns null when nothing valid can be derived — the caller then asks for an explicit
 * slug instead of sending a doomed create.
 */
export function deriveSlug(repoUrl) {
  const basename = repoBasename(repoUrl);
  if (!basename) return null;

  const slug = basename
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, SLUG_MAX_LENGTH)
    // A mid-string hyphen can land last after truncation; the server's format regex
    // requires an alphanumeric final character.
    .replace(/-+$/, "");

  return slug.length >= SLUG_MIN_LENGTH ? slug : null;
}

/** Extract the project object from a resolve/create response (`{ project: {...} }`). */
function projectOf(result) {
  return result?.project ?? null;
}

function channelSummary(project, { created, raced = false, source }) {
  return {
    project_id: project?.id ?? null,
    kind: project?.kind ?? null,
    slug: project?.slug ?? null,
    name: project?.name ?? null,
    created,
    ...(raced && { raced: true }),
    source,
  };
}

/**
 * Remediation text for a failed kb-scope create. The two realistic causes need
 * different next moves, and neither is guessable from the raw status.
 */
function createRemediation(status) {
  if (status === 403) {
    return (
      "The kb-scope create was refused. This is the agent-native path (#331/#505), so a " +
      "403 here is NOT the create_project tier wall — check that the key is an agent-role " +
      "key for this tenant (get_tenant reports capabilities.kb_project_scopes)."
    );
  }
  if (status === 422) {
    return (
      "The kb-scope create was rejected. Most likely the tenant is at its max_projects cap " +
      "(free a slot with archive_kb_scope) or the derived slug is invalid — pass an explicit " +
      "slug. Re-resolution already ran, so this is not a duplicate-slug race."
    );
  }
  return null;
}

/**
 * Resolve the repo's channel, creating a kb scope when none exists.
 *
 * Returns a channel summary, or an `apiCall`-shaped failure.
 */
async function ensureChannel(
  { project_id, repo_url, slug, name, description, tech_stack, create_channel },
  { resolveProject, createKbScope },
) {
  // An explicit project_id is taken at face value — the caller already resolved it, and
  // channel_post is the authority on whether it is writable.
  if (project_id) {
    return channelSummary({ id: project_id }, { created: false, source: "explicit" });
  }

  if (!repo_url && !slug) {
    return failure(
      "validate",
      0,
      "Supply one of: repo_url (the repo's git remote — the usual case, run " +
        "'git remote get-url origin'), slug, or an already-known project_id.",
    );
  }

  const resolved = await resolveProject({ slug, repo_url });
  if (resolved?.error !== true) {
    const project = projectOf(resolved);
    if (project?.id) {
      return channelSummary(project, { created: false, source: "resolved" });
    }
    // 2xx with no project is not something any current server version returns; treat it
    // as a resolve failure rather than silently creating a duplicate scope.
    return failure(
      "resolve",
      0,
      "resolve_project returned success but no project — refusing to create a channel on " +
        "an ambiguous resolve. Pass project_id explicitly.",
    );
  }

  // Only a genuine "no project for this repo" is recoverable by creating one. A 401/403/
  // 5xx means the resolve itself failed; creating a scope would paper over it.
  if (resolved.status !== 404) {
    return failure("resolve", resolved.status, resolved.body);
  }

  if (create_channel === false) {
    return failure(
      "resolve",
      404,
      `No loopctl project exists for this repo and create_channel is false, so no channel ` +
        `was created. Re-run with create_channel omitted (it defaults to true) to create a ` +
        `kb scope for it, or create one explicitly with create_kb_scope.`,
    );
  }

  const createSlug = slug || deriveSlug(repo_url);
  if (!createSlug) {
    return failure(
      "validate",
      0,
      `Could not derive a valid project slug from repo_url ${JSON.stringify(repo_url)} ` +
        `(needs ${SLUG_MIN_LENGTH}-${SLUG_MAX_LENGTH} chars of lowercase alphanumerics and ` +
        `hyphens). Pass an explicit slug.`,
    );
  }

  const created = await createKbScope({
    name: name || repoBasename(repo_url) || createSlug,
    slug: createSlug,
    repo_url,
    description,
    tech_stack,
  });

  if (created?.error === true) {
    // A concurrent session may have created the same scope between our resolve and our
    // create (the slug is deterministic, so both sessions target the same row). Re-resolve
    // before reporting failure so a race converges on ONE scope instead of erroring.
    const reresolved = await resolveProject({ slug: createSlug, repo_url });
    const raceWinner = reresolved?.error !== true ? projectOf(reresolved) : null;
    if (raceWinner?.id) {
      return channelSummary(raceWinner, { created: false, raced: true, source: "resolved" });
    }

    const remediation = createRemediation(created.status);
    return failure("create_channel", created.status, created.body, {
      attempted_slug: createSlug,
      ...(remediation && { remediation }),
    });
  }

  const project = projectOf(created);
  if (!project?.id) {
    return failure(
      "create_channel",
      0,
      "create_kb_scope returned success but no project id; cannot post the handoff.",
    );
  }

  return channelSummary(project, { created: true, source: "created" });
}

/**
 * Compose the whole sender-side handoff: resolve-or-create the channel, then post the
 * correctly-keyed pointer.
 *
 * `deps` injects the three raw HTTP calls (`resolveProject`, `createKbScope`,
 * `channelPost`), each returning an `apiCall`-shaped result.
 */
export async function createHandoff(args = {}, deps = {}) {
  const {
    anchor,
    body,
    project_id,
    repo_url,
    slug,
    name,
    description,
    tech_stack,
    to_host,
    to_capability,
    refs,
    create_channel = true,
  } = args;

  const keyed = handoffKey(anchor);
  if (keyed.error) return failure("validate", 0, keyed.error);

  if (typeof body !== "string" || !body.trim()) {
    return failure(
      "validate",
      0,
      "body is required, and it is a POINTER not a payload: a one-line TL;DR plus where the " +
        "full context lives (a GitHub issue/PR comment, a docs/ file, or a knowledge " +
        "article). The receiver sees only a bounded preview of it.",
    );
  }

  const channel = await ensureChannel(
    { project_id, repo_url, slug, name, description, tech_stack, create_channel },
    deps,
  );
  if (channel?.error === true) return channel;

  const posted = await deps.channelPost({
    project_id: channel.project_id,
    key: keyed.key,
    body,
    refs,
    to_host,
    to_capability,
  });

  if (posted?.error === true) {
    // Report the channel we resolved/created alongside the post failure — otherwise a
    // freshly created scope looks like it never happened and the retry creates another.
    return failure("post", posted.status, posted.body, { channel });
  }

  return {
    handoff: {
      key: keyed.key,
      anchor: keyed.anchor,
      channel,
      post: posted?.post ?? posted,
      meta: posted?.meta,
      receiver_next: [
        `channel_handoffs({ project_id: "${channel.project_id}", host: "<their hostname>" })`,
        `channel_claim({ project_id: "${channel.project_id}", ref: "${keyed.key}" })`,
        `channel_done({ project_id: "${channel.project_id}", ref: "${keyed.key}" })`,
      ],
    },
  };
}
