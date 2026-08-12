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
 * WHAT IS ACTUALLY AVAILABLE — re-measured 2026-08-12 by reading /proc/<mcp-pid>/environ on
 * a live session, which corrected two entries an earlier pass got wrong:
 *
 *   CLAUDE_CODE_SESSION_ID=<uuid>   -> session id, available
 *   CLAUDE_CODE_ENTRYPOINT=cli      -> entrypoint, available
 *   CLAUDE_SESSION_ID               -> ABSENT (the CODE_ spelling is the one that is set)
 *   CLAUDE_EFFORT                   -> ABSENT from THIS process. It is set for Bash-tool
 *                                      invocations, which is where the earlier claim that
 *                                      it was "available" came from; the MCP server does
 *                                      not get it, so `effort` is enriched offline.
 *   CLAUDE_CODE_CHILD_SESSION       -> ABSENT, and it would not mean what it looks like:
 *                                      it is set to 1 for Bash-tool invocations of a MAIN
 *                                      session, so it marks "a child PROCESS", not "a
 *                                      dispatched agent".
 *   (no model variable)             -> MODEL IS NOT AVAILABLE
 *
 * THE KIND REPORTED HERE IS THE SESSION'S, NOT THE CALLER'S. One MCP server process is
 * spawned per session and serves the main session AND every agent it dispatches, and the
 * environment above is read once and cached for the life of that process. So `kind` is a
 * property of the session, and every search it labels comes back `main`. The three-way
 * main/subagent/workflow split a measurement actually needs is recoverable only from the
 * transcript, where `isSidechain` plus the file's path give it unambiguously.
 *
 * Two fields are therefore sent as JOIN KEYS rather than as answers: `session_id` is what
 * lets `mix loopctl.enrich_search_events` find the transcript that records the model, the
 * effort and the real kind. Note that a RESUMED session breaks even that — the new process
 * reports a fresh session id while the transcript keeps appending under the original — so
 * the enrichment carries a query-only fallback for exactly that case.
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

  // The SESSION's kind — see the header. This process is shared by the main session and
  // every agent it dispatches, so in practice this resolves to "main" for all of them and
  // is NOT caller-level evidence. It is still worth sending: it is the only thing available
  // before the offline enrichment runs, and the enrichment treats it as an assertion to be
  // corrected rather than as a value to be preserved.
  //
  // Do not try to widen it to three values from the environment. CLAUDE_CODE_WORKFLOWS is a
  // feature flag present in main sessions too, and CLAUDE_CODE_CHILD_SESSION marks a child
  // PROCESS rather than a dispatched agent. Guessing here would be worse than the null it
  // replaces, because the number this column exists to support is a comparison BETWEEN
  // kinds.
  const child = env("CLAUDE_CODE_CHILD_SESSION");
  if (child !== undefined) {
    ctx.kind = child === "1" || child.toLowerCase() === "true" ? "child" : "main";
  } else if (ctx.session_id) {
    // A MAIN session sets no child marker at all, so keying on the marker alone filed
    // every main session under NULL — beside every request from an older client that sends
    // no context, which is the one population NULL has to keep meaning. An absent marker on
    // a recognisable session IS main; with nothing identifying the caller, kind stays
    // absent rather than guessed.
    ctx.kind = "main";
  }

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
