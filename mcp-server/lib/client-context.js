/**
 * Client context reported alongside every search (#658).
 *
 * WHY THE CLIENT HAS TO SUPPLY THIS. None of it is derivable server-side. An api_key
 * identifies a KEY, and under the v2 dispatch pattern a key is minted per dispatch, so the
 * server cannot tell which agent searched, at what effort, from which repo, or whether the
 * caller was a main session or a dispatched subagent. The MCP server runs inside the
 * agent's own process, so it can simply read its environment.
 *
 * UNTRUSTED BY CONSTRUCTION. Every field here is client-asserted and trivially spoofable.
 * It is ANALYTICS ONLY and must never gate access or authorize anything — the api_key
 * remains the sole authority. The server stores these under a `client_` prefix so no later
 * reader mistakes them for server-derived facts.
 *
 * WHAT IS ACTUALLY AVAILABLE (verified on a live session, 2026-08-12):
 *
 *   CLAUDE_EFFORT=high              -> effort, available
 *   CLAUDE_SESSION_ID=<uuid>        -> session id, available
 *   CLAUDE_CODE_CHILD_SESSION=1     -> subagent vs main session, available
 *   CLAUDE_CODE_ENTRYPOINT=cli      -> entrypoint, available
 *   (no model variable)             -> MODEL IS NOT AVAILABLE
 *
 * The model is deliberately still sent when a variable for it appears, because the session
 * TRANSCRIPT does record it (`message.model`, e.g. `claude-opus-5`) keyed by session id —
 * so `client_session_id` is the join key that enriches model offline today, and the field
 * fills itself in the day the runtime exposes one.
 */

import { execFileSync } from "node:child_process";
import os from "node:os";

function env(name) {
  const v = process.env[name];
  return typeof v === "string" && v.trim() !== "" ? v.trim() : undefined;
}

/**
 * The repo the AGENT was working in — which is NOT the project a KB search was scoped to.
 * "Which repos lean on the knowledge base, and which never touch it" cannot be answered
 * without it, and the scoped project_id does not answer it.
 *
 * Derived from the git remote so it is stable across machines and checkout paths; falls
 * back to the directory basename when there is no remote. Cached: this runs per search and
 * shelling out per call would put a process spawn on the hot path.
 */
let repoCache;
function detectRepo() {
  if (repoCache !== undefined) return repoCache;
  repoCache = null;
  try {
    const remote = execFileSync("git", ["remote", "get-url", "origin"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 2000,
    }).trim();
    // Normalise git@host:owner/repo.git and https://host/owner/repo(.git) to owner/repo.
    const m = remote.match(/[:/]([^/:]+\/[^/]+?)(?:\.git)?$/);
    if (m) repoCache = m[1];
  } catch {
    try {
      repoCache = process.cwd().split("/").filter(Boolean).pop() || null;
    } catch {
      repoCache = null;
    }
  }
  return repoCache;
}

/** Test seam: forget the cached repo. */
function resetRepoCache() {
  repoCache = undefined;
}

/**
 * Builds the client-context payload. Every field is optional — a missing value is omitted
 * rather than sent as null, so "we could not observe this" and "this was empty" stay
 * distinguishable in the data.
 */
function clientContext({ version } = {}) {
  const ctx = {
    session_id: env("CLAUDE_SESSION_ID") || env("CLAUDE_CODE_SESSION_ID"),
    effort: env("CLAUDE_EFFORT"),
    model: env("CLAUDE_MODEL") || env("ANTHROPIC_MODEL"),
    host: os.hostname(),
    repo: detectRepo() || undefined,
    entrypoint: env("CLAUDE_CODE_ENTRYPOINT"),
    version,
  };

  // A dispatched subagent sets CLAUDE_CODE_CHILD_SESSION=1. Recorded as a real boolean so
  // the two populations can be compared; left absent when the variable is not set at all,
  // rather than guessed as false.
  const child = env("CLAUDE_CODE_CHILD_SESSION");
  if (child !== undefined) ctx.subagent = child === "1" || child.toLowerCase() === "true";

  for (const k of Object.keys(ctx)) {
    if (ctx[k] === undefined || ctx[k] === null || ctx[k] === "") delete ctx[k];
  }
  return ctx;
}

/**
 * Encodes the context for transport as a single header. Base64 keeps arbitrary repo names
 * and hostnames from breaking header parsing, and one header keeps the surface small.
 * Returns undefined when there is nothing to report, so no empty header is sent.
 */
function clientContextHeader(opts) {
  const ctx = clientContext(opts);
  if (Object.keys(ctx).length === 0) return undefined;
  return Buffer.from(JSON.stringify(ctx), "utf8").toString("base64");
}

export { clientContext, clientContextHeader, detectRepo, resetRepoCache };
