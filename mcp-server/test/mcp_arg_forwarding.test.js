/**
 * Regression tests for the MCP server arg-forwarding + apiCall robustness fixes:
 *
 *   - #247 (mcp-01): list_projects must forward page/page_size (dispatch dropped args).
 *   - #248 (mcp-02): knowledge_ingestion_jobs must forward limit/offset/since_days.
 *   - #249 (mcp-03): apiCall must not throw on an empty/invalid JSON body when the
 *     response carries a JSON content-type — it returns a STRUCTURED error instead.
 *
 * Uses the Node.js built-in test runner (node:test). Run: node --test test/*.test.js
 *
 * SINGLE SOURCE OF TRUTH: the query-building and JSON-parse logic that had bugs
 * lives in ../lib/http-helpers.js, imported by BOTH the real server (index.js) and
 * these tests. So the behavioral tests below exercise the exact code the server
 * ships — a regression in projectsPath / ingestionJobsPath / parseJsonResponseBody
 * fails here. The remaining tests pin the WIRING in index.js (that the handlers and
 * apiCall actually call the shared helpers, and the dispatch passes args through),
 * so drift in either the logic or its use fails CI.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  buildQuery,
  projectsPath,
  ingestionJobsPath,
  llmUsagePath,
  parseJsonResponseBody,
} from "../lib/http-helpers.js";

const INDEX_SRC = readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "index.js"),
  "utf8",
);

/**
 * The source of ONE top-level async function, bounded at the next top-level
 * `async function` declaration.
 *
 * Source-scan assertions of the form /async function foo\([\s\S]*?<needle>/ span
 * FORWARD without limit, so they can be satisfied by a LATER function's body — e.g. a
 * `channelPost` assertion passing on `channelLock`, which also sets `payload.host` and
 * `payload.session_id`. That is a vacuous pass: the guard survives even when the function
 * it names loses the behavior. Slicing the function out FIRST makes every assertion below
 * provably about the named function.
 */
function functionSource(name) {
  const declaration = `async function ${name}(`;
  const start = INDEX_SRC.indexOf(declaration);
  assert.notEqual(start, -1, `index.js must define ${declaration}`);
  const rest = INDEX_SRC.slice(start + declaration.length);
  const next = rest.indexOf("\nasync function ");
  const body = next === -1 ? rest : rest.slice(0, next);
  // Non-empty by construction, but assert it so a future refactor that empties the
  // function cannot make the slice-based assertions pass on "".
  assert.ok(body.trim().length > 0, `${name} must have a body`);
  return body;
}

// ---------------------------------------------------------------------------
// buildQuery — the shared primitive
// ---------------------------------------------------------------------------

describe("buildQuery (shared query-string primitive)", () => {
  test("emits set pairs and skips null/undefined", () => {
    assert.equal(buildQuery([["a", 1], ["b", undefined], ["c", null], ["d", 0]]), "?a=1&d=0");
  });

  test("returns empty string when nothing is set", () => {
    assert.equal(buildQuery([["a", undefined], ["b", null]]), "");
  });
});

// ---------------------------------------------------------------------------
// #247 (mcp-01): list_projects forwards page/page_size (REAL projectsPath)
// ---------------------------------------------------------------------------

describe("#247 mcp-01: list_projects pagination (real projectsPath)", () => {
  test("forwards page and page_size", () => {
    const url = new URL(`https://x${projectsPath({ page: 2, page_size: 50 })}`);
    assert.equal(url.pathname, "/api/v1/projects");
    assert.equal(url.searchParams.get("page"), "2");
    assert.equal(url.searchParams.get("page_size"), "50");
  });

  test("forwards page alone", () => {
    assert.equal(projectsPath({ page: 3 }), "/api/v1/projects?page=3");
  });

  test("omits pagination params when none are supplied", () => {
    assert.equal(projectsPath(), "/api/v1/projects");
    assert.equal(projectsPath({}), "/api/v1/projects");
  });

  test("index.js listProjects uses projectsPath(args) and passes args from dispatch", () => {
    assert.match(
      INDEX_SRC,
      /async function listProjects\(args = \{\}\) \{[\s\S]*?projectsPath\(args\)/,
      "listProjects must delegate to the shared projectsPath(args)",
    );
    assert.match(
      INDEX_SRC,
      /case "list_projects":\s*\n\s*return await listProjects\(args\);/,
      "the list_projects dispatch case must call listProjects(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// #411 gap1: resolve_project (cheap repo -> project_id resolution)
// ---------------------------------------------------------------------------

describe("#411 gap1: resolve_project wiring", () => {
  test("TOOLS declares a resolve_project tool", () => {
    assert.match(INDEX_SRC, /name: "resolve_project",/, 'must declare a "resolve_project" tool');
  });

  test("resolveProject GETs /projects/resolve with slug/repo_url/name on the agent key", () => {
    // The request lives in resolveProjectRaw so the `handoff` composition (#528) can
    // reuse it; resolveProject is a toContent wrapper over it (asserted below).
    const src = functionSource("resolveProjectRaw");
    assert.match(
      src,
      /\{ slug, repo_url, name \} = \{\}\) \{[\s\S]*?\/api\/v1\/projects\/resolve\?\$\{params\}[\s\S]*?LOOPCTL_AGENT_KEY/,
      "resolveProjectRaw must GET /api/v1/projects/resolve with a query string on the agent key",
    );
    assert.match(
      functionSource("resolveProject"),
      /return toContent\(await resolveProjectRaw\(args\)\);/,
      "resolveProject must delegate to resolveProjectRaw",
    );
    assert.match(INDEX_SRC, /if \(slug\) params\.set\("slug", slug\);/);
    assert.match(INDEX_SRC, /if \(repo_url\) params\.set\("repo_url", repo_url\);/);
    assert.match(INDEX_SRC, /if \(name\) params\.set\("name", name\);/);
  });

  test("the resolve_project dispatch case calls resolveProject(args)", () => {
    assert.match(
      INDEX_SRC,
      /case "resolve_project":\s*\n\s*return await resolveProject\(args\);/,
      "the resolve_project dispatch case must call resolveProject(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// #418: create_kb_scope (KB-only project scope, agent-createable)
// ---------------------------------------------------------------------------

describe("#418: create_kb_scope wiring", () => {
  test("TOOLS declares a create_kb_scope tool", () => {
    assert.match(INDEX_SRC, /name: "create_kb_scope",/, 'must declare a "create_kb_scope" tool');
  });

  test("createKbScope POSTs /kb-scopes on the AGENT key (not the orch key)", () => {
    assert.match(
      functionSource("createKbScopeRaw"),
      /"POST",\s*"\/api\/v1\/kb-scopes",\s*body,\s*process\.env\.LOOPCTL_AGENT_KEY/,
      "createKbScopeRaw must POST /api/v1/kb-scopes with the agent key",
    );
    assert.match(
      functionSource("createKbScope"),
      /return toContent\(await createKbScopeRaw\(args\)\);/,
      "createKbScope must delegate to createKbScopeRaw",
    );
  });

  test("the create_kb_scope dispatch case calls createKbScope(args)", () => {
    assert.match(
      INDEX_SRC,
      /case "create_kb_scope":\s*\n\s*return await createKbScope\(args\);/,
      "the create_kb_scope dispatch case must call createKbScope(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// #39.4: channel_post / channel_recent (Repo Coordination Bus proxy tools)
// ---------------------------------------------------------------------------

describe("#39.4: channel_post / channel_recent wiring", () => {
  test("TOOLS declares channel_post and channel_recent", () => {
    assert.match(INDEX_SRC, /name: "channel_post",/, 'must declare a "channel_post" tool');
    assert.match(INDEX_SRC, /name: "channel_recent",/, 'must declare a "channel_recent" tool');
  });

  test("channelPost POSTs /channel/posts on the AGENT key", () => {
    // The request lives in channelPostRaw (reused by the `handoff` composition, #528);
    // channelPost is a toContent wrapper over it.
    assert.match(
      functionSource("channelPostRaw"),
      /"POST",\s*"\/api\/v1\/channel\/posts",\s*payload,\s*process\.env\.LOOPCTL_AGENT_KEY/,
      "channelPostRaw must POST /api/v1/channel/posts with the agent key",
    );
    assert.match(
      functionSource("channelPost"),
      /return toContent\(await channelPostRaw\(args\)\);/,
      "channelPost must delegate to channelPostRaw",
    );
  });

  test("channelPost auto-fills host from os.hostname()", () => {
    assert.match(
      functionSource("channelPostRaw"),
      /payload\.host = os\.hostname\(\)/,
      "channelPostRaw must set host from os.hostname()",
    );
  });

  test("channelPost auto-fills session_id from CHANNEL_SESSION_ID (CLAUDE_SESSION_ID or process-lifetime fallback, US-454)", () => {
    // US-454 (defect 1): before the fallback, an absent CLAUDE_SESSION_ID meant
    // NO session_id was sent and the keyed (handoff) path 422d — silently
    // forcing undiscoverable keyless posts. The proxy now ALWAYS sends one:
    // the real session id when present, else ONE random id minted at process
    // start so same-process retries upsert the same slot.
    assert.match(
      INDEX_SRC,
      /const CHANNEL_SESSION_ID = process\.env\.CLAUDE_SESSION_ID \|\| crypto\.randomUUID\(\);/,
      "must define CHANNEL_SESSION_ID as CLAUDE_SESSION_ID with a randomUUID fallback",
    );
    assert.match(
      functionSource("channelPostRaw"),
      /payload\.session_id = CHANNEL_SESSION_ID;/,
      "channelPostRaw must always send CHANNEL_SESSION_ID",
    );
  });

  test("channelPost forwards advisory to_host/to_capability only when set (US-40.A5)", () => {
    // to_host/to_capability are caller args (unlike auto-filled host/session_id),
    // conditionally added to the payload so an unset addressing field is omitted
    // rather than sent as undefined. AC-40.A5.4 requires them settable via MCP.
    const src = functionSource("channelPostRaw");
    assert.match(
      src,
      /if \(to_host\) payload\.to_host = to_host;/,
      "channelPostRaw must forward to_host only when set",
    );
    assert.match(
      src,
      /if \(to_capability\) payload\.to_capability = to_capability;/,
      "channelPostRaw must forward to_capability only when set",
    );
    assert.match(
      src,
      /^\{[^}]*\bto_host\b[^}]*\bto_capability\b[^}]*\}\)/,
      "channelPostRaw must destructure to_host and to_capability from its args",
    );
    // The composed one-call route (#528) must forward advisory addressing too; that is
    // covered BEHAVIORALLY in test/handoff_tool.test.js (asserting the post args), which
    // is stronger than a source scan.
  });

  test("channelPost forwards supersedes only when set (US-454 defect 3)", () => {
    const src = functionSource("channelPostRaw");
    assert.match(
      src,
      /if \(supersedes\) payload\.supersedes = supersedes;/,
      "channelPostRaw must forward supersedes only when set",
    );
    assert.match(
      src,
      /^\{[^}]*\bsupersedes\b[^}]*\}\)/,
      "channelPostRaw must destructure supersedes from its args",
    );
  });

  test("channelHandoffs forwards only_mine=true only when set (US-454 defect 2)", () => {
    assert.match(
      INDEX_SRC,
      /async function channelHandoffs\([\s\S]*?if \(only_mine\) params\.set\("only_mine", "true"\);/,
      "channelHandoffs must forward only_mine=true only when set",
    );
  });

  test("channelRecent GETs /channel/posts on the AGENT key", () => {
    assert.match(
      INDEX_SRC,
      /async function channelRecent\([\s\S]*?"GET",\s*`\/api\/v1\/channel\/posts\?\$\{params\}`,\s*null,\s*process\.env\.LOOPCTL_AGENT_KEY/,
      "channelRecent must GET /api/v1/channel/posts with a query string on the agent key",
    );
  });

  test("the channel_post `key` property documents the session fallbacks (US-454)", () => {
    // US-454 (defect 1): the keyed path no longer hard-requires a Claude Code
    // session — the description must document the proxy's process-lifetime
    // fallback AND the server's surrogate rescue (with its response-meta
    // marker), so agents know a keyed post always lands and how to tell when a
    // fallback fired.
    assert.match(
      INDEX_SRC,
      /Optional per-session working-state slot key[\s\S]*?process-lifetime fallback[\s\S]*?surrogate[\s\S]*?session_id_source/,
      "the channel_post `key` description must document the session fallbacks (US-454)",
    );
  });

  test("the channel_post dispatch case calls channelPost(args)", () => {
    assert.match(
      INDEX_SRC,
      /case "channel_post":\s*\n\s*return await channelPost\(args\);/,
      "the channel_post dispatch case must call channelPost(args)",
    );
  });

  test("the channel_recent dispatch case calls channelRecent(args)", () => {
    assert.match(
      INDEX_SRC,
      /case "channel_recent":\s*\n\s*return await channelRecent\(args\);/,
      "the channel_recent dispatch case must call channelRecent(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// US-40.B1: channel_claim / channel_release / channel_done (exactly-once handoff)
// ---------------------------------------------------------------------------

describe("US-40.B1: channel_claim / channel_release / channel_done wiring", () => {
  test("TOOLS declares channel_claim, channel_release, channel_done", () => {
    assert.match(INDEX_SRC, /name: "channel_claim",/, 'must declare a "channel_claim" tool');
    assert.match(INDEX_SRC, /name: "channel_release",/, 'must declare a "channel_release" tool');
    assert.match(INDEX_SRC, /name: "channel_done",/, 'must declare a "channel_done" tool');
  });

  test("channel_claim description maps 409 already_claimed to an honest 'ref is taken' message", () => {
    assert.match(
      INDEX_SRC,
      /409 already_claimed[\s\S]*?either another agent owns it, or you already completed it/,
      "channel_claim must honestly tell a loser the ref is taken — either another agent owns it or you already completed it (move on)",
    );
  });

  test("channelClaim POSTs /channel/claims on the AGENT key", () => {
    assert.match(
      INDEX_SRC,
      /async function channelClaim\([\s\S]*?"POST",\s*"\/api\/v1\/channel\/claims",\s*payload,\s*process\.env\.LOOPCTL_AGENT_KEY/,
      "channelClaim must POST /api/v1/channel/claims with the agent key",
    );
  });

  test("channelRelease POSTs /channel/claims/release on the AGENT key", () => {
    assert.match(
      INDEX_SRC,
      /async function channelRelease\([\s\S]*?"POST",\s*"\/api\/v1\/channel\/claims\/release",[\s\S]*?process\.env\.LOOPCTL_AGENT_KEY/,
      "channelRelease must POST /api/v1/channel/claims/release with the agent key",
    );
  });

  test("channelDone POSTs /channel/claims/done on the AGENT key", () => {
    assert.match(
      INDEX_SRC,
      /async function channelDone\([\s\S]*?"POST",\s*"\/api\/v1\/channel\/claims\/done",[\s\S]*?process\.env\.LOOPCTL_AGENT_KEY/,
      "channelDone must POST /api/v1/channel/claims/done with the agent key",
    );
  });

  test("the claim dispatch cases call the right functions", () => {
    assert.match(
      INDEX_SRC,
      /case "channel_claim":\s*\n\s*return await channelClaim\(args\);/,
      "the channel_claim dispatch case must call channelClaim(args)",
    );
    assert.match(
      INDEX_SRC,
      /case "channel_release":\s*\n\s*return await channelRelease\(args\);/,
      "the channel_release dispatch case must call channelRelease(args)",
    );
    assert.match(
      INDEX_SRC,
      /case "channel_done":\s*\n\s*return await channelDone\(args\);/,
      "the channel_done dispatch case must call channelDone(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// US-40.4: channel_lock / channel_unlock / channel_locks (ADVISORY file soft-locks)
// ---------------------------------------------------------------------------

describe("US-40.4: channel_lock / channel_unlock / channel_locks wiring", () => {
  test("TOOLS declares channel_lock, channel_unlock, channel_locks", () => {
    assert.match(INDEX_SRC, /name: "channel_lock",/, 'must declare a "channel_lock" tool');
    assert.match(INDEX_SRC, /name: "channel_unlock",/, 'must declare a "channel_unlock" tool');
    assert.match(INDEX_SRC, /name: "channel_locks",/, 'must declare a "channel_locks" tool');
  });

  test("channel_lock is described as ADVISORY and explicitly NOT the exactly-once claim", () => {
    // The whole failure mode this story guards against is an agent reading the
    // soft-lock as a mutex (or as the handoff claim). Both disclaimers are part
    // of the tool contract, not just the docs.
    assert.match(
      INDEX_SRC,
      /name: "channel_lock",[\s\S]*?ADVISORY ONLY: it NEVER blocks anyone/,
      "channel_lock must state it never blocks",
    );
    assert.match(
      INDEX_SRC,
      /name: "channel_lock",[\s\S]*?Two sessions CAN hold a lock on the same file/,
      "channel_lock must state two sessions can hold the same file",
    );
    assert.match(
      INDEX_SRC,
      /name: "channel_lock",[\s\S]*?This is NOT the exactly-once handoff claim/,
      "channel_lock must disclaim being the handoff claim",
    );
  });

  test("channel_lock documents the server-clamped TTL bounds", () => {
    assert.match(
      INDEX_SRC,
      /name: "channel_lock",[\s\S]*?SERVER-CLAMPED to \[60, 3600\]/,
      "channel_lock must document the [60, 3600] clamp",
    );
  });

  // Review #451: the release slot's session_id is CLIENT-supplied and channel_locks
  // publishes it, so the enforced boundary is the server-stamped agent, not the
  // session. The tool description must not overclaim per-session isolation.
  test("channel_unlock describes the scope as per-AGENT, not per-session", () => {
    assert.match(
      INDEX_SRC,
      /name: "channel_unlock",[\s\S]*?scoped to your AGENT', not to your session/,
      "channel_unlock must state the guarantee is agent-scoped",
    );
  });

  test("channel_lock states a session-less write is rejected, not surrogate-rescued", () => {
    assert.match(
      INDEX_SRC,
      /name: "channel_lock",[\s\S]*?a lock write with no session_id is REJECTED/,
      "channel_lock must state a session-less write is rejected",
    );
  });

  // Review #451: the fairness partition is the SERVER-STAMPED agent_id alone.
  // Partitioning on the client-supplied session_id too would let a caller rotating
  // session ids escape the bound entirely, so the tool description must not promise
  // a per-(agent, session) bound the server does not enforce.
  test("channel_locks documents the per-AGENT fairness bound", () => {
    assert.match(
      INDEX_SRC,
      /name: "channel_locks",[\s\S]*?Fairness-bounded: a single AGENT \(server-stamped from the key, so rotating session_id does not escape it\) contributes at most 20 rows/,
      "channel_locks must document the per-agent fairness bound",
    );
  });

  // Review #451: the fairness cap filters INSIDE the scope, so meta.overflow (the
  // page cap) cannot see its drops. A client told only about overflow would read
  // `overflow: false` on a page that had silently dropped live locks.
  test("channel_locks documents BOTH truncation flags", () => {
    assert.match(
      INDEX_SRC,
      /name: "channel_locks",[\s\S]*?meta\.overflow[\s\S]*?meta\.holders_truncated/,
      "channel_locks must document meta.overflow AND meta.holders_truncated",
    );
  });

  // Review #451: the reserved namespace is a behavior change on an EXISTING tool —
  // an agent already posting key: "claim:story-812" must be forewarned in the tool
  // it actually calls, not only in the new lock tools.
  test("channel_post warns that the claim: key namespace is reserved", () => {
    assert.match(
      INDEX_SRC,
      /name: "channel_post",[\s\S]*?RESERVED KEY NAMESPACE: keys beginning with 'claim:'[\s\S]*?REJECTED here with a 422/,
      "channel_post must document the reserved claim: namespace",
    );
  });

  // Review #451: locks ride channel_recent but are capped there and do not move
  // has_more, so the read must not be cited as evidence that a file is free.
  test("channel_recent warns that its lock view is capped", () => {
    assert.match(
      INDEX_SRC,
      /name: "channel_recent",[\s\S]*?LOCK VISIBILITY CAVEAT[\s\S]*?call channel_locks/,
      "channel_recent must carry the lock-visibility caveat",
    );
  });

  test("channelLock POSTs /channel/locks on the AGENT key", () => {
    assert.match(
      INDEX_SRC,
      /async function channelLock\([\s\S]*?"POST",\s*"\/api\/v1\/channel\/locks",\s*payload,\s*process\.env\.LOOPCTL_AGENT_KEY/,
      "channelLock must POST /api/v1/channel/locks with the agent key",
    );
  });

  test("channelLock forwards ttl_seconds and note only when set", () => {
    assert.match(
      INDEX_SRC,
      /async function channelLock\([\s\S]*?if \(ttl_seconds\) payload\.ttl_seconds = ttl_seconds;/,
      "channelLock must forward ttl_seconds only when set",
    );
    assert.match(
      INDEX_SRC,
      /async function channelLock\([\s\S]*?if \(note\) payload\.body = note;/,
      "channelLock must forward the optional note as the post body",
    );
  });

  test("host/session_id stay PROXY-supplied on the lock path (never caller args)", () => {
    // session_id is what makes a lock refreshable in place and releasable by
    // slot; a caller-supplied one would let a client address another session's slot.
    assert.match(
      INDEX_SRC,
      /async function channelLock\([\s\S]*?payload\.host = os\.hostname\(\);[\s\S]*?payload\.session_id = CHANNEL_SESSION_ID;/,
      "channelLock must auto-fill host and session_id",
    );
    assert.match(
      INDEX_SRC,
      /async function channelUnlock\([\s\S]*?payload\.session_id = CHANNEL_SESSION_ID;/,
      "channelUnlock must auto-fill session_id",
    );
    // Neither tool schema may expose host/session_id as caller inputs.
    const lockSchema = INDEX_SRC.match(
      /name: "channel_lock",[\s\S]*?required: \["project_id", "target"\]/,
    );
    assert.ok(lockSchema, "channel_lock schema must be findable");
    assert.ok(
      !/session_id:/.test(lockSchema[0]) && !/\bhost:/.test(lockSchema[0]),
      "channel_lock must NOT declare host/session_id as caller args",
    );
  });

  test("channelUnlock POSTs /channel/locks/release on the AGENT key", () => {
    assert.match(
      INDEX_SRC,
      /async function channelUnlock\([\s\S]*?"POST",\s*"\/api\/v1\/channel\/locks\/release",\s*payload,\s*process\.env\.LOOPCTL_AGENT_KEY/,
      "channelUnlock must POST /api/v1/channel/locks/release with the agent key",
    );
  });

  test("channelLocks GETs /channel/locks with project_id and limit on the AGENT key", () => {
    assert.match(
      INDEX_SRC,
      /async function channelLocks\([\s\S]*?params\.set\("project_id", project_id\)[\s\S]*?params\.set\("limit", limit\)[\s\S]*?"GET",\s*`\/api\/v1\/channel\/locks\?\$\{params\}`,\s*null,\s*process\.env\.LOOPCTL_AGENT_KEY/,
      "channelLocks must GET /api/v1/channel/locks with the agent key, forwarding project_id and limit",
    );
  });

  test("the lock dispatch cases call the right functions", () => {
    assert.match(
      INDEX_SRC,
      /case "channel_lock":\s*\n\s*return await channelLock\(args\);/,
      "the channel_lock dispatch case must call channelLock(args)",
    );
    assert.match(
      INDEX_SRC,
      /case "channel_unlock":\s*\n\s*return await channelUnlock\(args\);/,
      "the channel_unlock dispatch case must call channelUnlock(args)",
    );
    assert.match(
      INDEX_SRC,
      /case "channel_locks":\s*\n\s*return await channelLocks\(args\);/,
      "the channel_locks dispatch case must call channelLocks(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// #39.7: channel_delete (Repo Coordination Bus redact path)
// ---------------------------------------------------------------------------

describe("#39.7: channel_delete wiring", () => {
  test("TOOLS declares channel_delete", () => {
    assert.match(INDEX_SRC, /name: "channel_delete",/, 'must declare a "channel_delete" tool');
  });

  test("channelDelete DELETEs /channel/posts/${post_id} on the AGENT key", () => {
    assert.match(
      INDEX_SRC,
      /async function channelDelete\([\s\S]*?"DELETE",\s*`\/api\/v1\/channel\/posts\/\$\{post_id\}`,\s*null,\s*process\.env\.LOOPCTL_AGENT_KEY/,
      "channelDelete must DELETE /api/v1/channel/posts/${post_id} with the agent key",
    );
  });

  test("the channel_delete tool requires post_id", () => {
    assert.match(
      INDEX_SRC,
      /name: "channel_delete",[\s\S]*?required: \["post_id"\]/,
      "the channel_delete inputSchema must require post_id",
    );
  });

  test("the channel_delete dispatch case calls channelDelete(args)", () => {
    assert.match(
      INDEX_SRC,
      /case "channel_delete":\s*\n\s*return await channelDelete\(args\);/,
      "the channel_delete dispatch case must call channelDelete(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// #40.D1: channel_get (full-body read) + untrusted-DATA framing (TC-40.D1.5)
// ---------------------------------------------------------------------------

describe("#40.D1: channel_get wiring + untrusted-DATA framing", () => {
  test("TOOLS declares channel_get requiring post_id", () => {
    assert.match(INDEX_SRC, /name: "channel_get",/, 'must declare a "channel_get" tool');
    assert.match(
      INDEX_SRC,
      /name: "channel_get",[\s\S]*?required: \["post_id"\]/,
      "the channel_get inputSchema must require post_id",
    );
  });

  test("channelGet GETs /channel/posts/${post_id} on the AGENT key", () => {
    assert.match(
      INDEX_SRC,
      /async function channelGet\([\s\S]*?"GET",\s*`\/api\/v1\/channel\/posts\/\$\{post_id\}`,\s*null,\s*process\.env\.LOOPCTL_AGENT_KEY/,
      "channelGet must GET /api/v1/channel/posts/${post_id} with the agent key",
    );
  });

  test("the channel_get dispatch case calls channelGet(args)", () => {
    assert.match(
      INDEX_SRC,
      /case "channel_get":\s*\n\s*return await channelGet\(args\);/,
      "the channel_get dispatch case must call channelGet(args)",
    );
  });

  test("channel_get frames the returned body as UNTRUSTED DATA (AC-40.D1.4)", () => {
    const getTool = /name: "channel_get",\s*\n\s*description:\s*\n?\s*"([^"]*)"/.exec(INDEX_SRC);
    assert.ok(getTool, "channel_get must have a description");
    assert.match(getTool[1], /UNTRUSTED DATA/, "channel_get body must be framed as UNTRUSTED DATA");
    assert.match(getTool[1], /NO auto-follow/i, "channel_get must state there is no auto-follow");
  });

  test("channel_recent frames returned bodies as UNTRUSTED DATA + bounded previews (AC-40.D1.2)", () => {
    const recentTool = /name: "channel_recent",\s*\n\s*description:\s*\n?\s*"([^"]*)"/.exec(
      INDEX_SRC,
    );
    assert.ok(recentTool, "channel_recent must have a description");
    assert.match(
      recentTool[1],
      /UNTRUSTED DATA/,
      "channel_recent bodies must be framed as UNTRUSTED DATA",
    );
    assert.match(
      recentTool[1],
      /body_preview/,
      "channel_recent must document the bounded body_preview",
    );
  });

  test("no fetch-and-follow / auto-follow tool exists (AC-40.D1.2/3)", () => {
    // The security posture forbids any tool that fetches a post AND acts on it.
    assert.doesNotMatch(
      INDEX_SRC,
      /name: "channel_[a-z_]*follow[a-z_]*"/,
      "there must be no channel_*follow* fetch-and-follow tool",
    );
    // No tool description should instruct the agent to FOLLOW a fetched body.
    assert.doesNotMatch(
      INDEX_SRC,
      /fetch [^"]*and follow/i,
      "no tool may offer a fetch-and-follow affordance",
    );
  });
});

// ---------------------------------------------------------------------------
// #40.E1: channel_graduate (graduate a coordination post into Knowledge)
// ---------------------------------------------------------------------------

describe("#40.E1: channel_graduate wiring", () => {
  test("TOOLS declares channel_graduate requiring post_id and title", () => {
    assert.match(
      INDEX_SRC,
      /name: "channel_graduate",/,
      'must declare a "channel_graduate" tool',
    );
    assert.match(
      INDEX_SRC,
      /name: "channel_graduate",[\s\S]*?required: \["post_id", "title"\]/,
      "the channel_graduate inputSchema must require post_id and title",
    );
  });

  test("channelGraduate POSTs /channel/posts/${post_id}/graduate on the AGENT key", () => {
    assert.match(
      INDEX_SRC,
      /async function channelGraduate\([\s\S]*?"POST",\s*`\/api\/v1\/channel\/posts\/\$\{post_id\}\/graduate`,\s*payload,\s*process\.env\.LOOPCTL_AGENT_KEY/,
      "channelGraduate must POST /api/v1/channel/posts/${post_id}/graduate with the agent key",
    );
  });

  test("the channel_graduate dispatch case calls channelGraduate(args)", () => {
    assert.match(
      INDEX_SRC,
      /case "channel_graduate":\s*\n\s*return await channelGraduate\(args\);/,
      "the channel_graduate dispatch case must call channelGraduate(args)",
    );
  });

  test("channel_graduate description states it is CONTENT-SELECTIVE and transient posts should expire (AC-40.E1.4/5)", () => {
    const gradTool = /name: "channel_graduate",\s*\n\s*description:\s*\n?\s*"([^"]*)"/.exec(
      INDEX_SRC,
    );
    assert.ok(gradTool, "channel_graduate must have a description");
    assert.match(
      gradTool[1],
      /REUSABLE/,
      "channel_graduate must state it is for a reusable finding",
    );
    assert.match(
      gradTool[1],
      /LEFT TO EXPIRE|left to expire/,
      "channel_graduate must say transient directives should be left to expire",
    );
  });
});

describe("KB-scope lifecycle: archive_kb_scope / restore_kb_scope wiring", () => {
  test("TOOLS declares archive_kb_scope and restore_kb_scope", () => {
    assert.match(INDEX_SRC, /name: "archive_kb_scope",/, 'must declare "archive_kb_scope"');
    assert.match(INDEX_SRC, /name: "restore_kb_scope",/, 'must declare "restore_kb_scope"');
  });

  test("archiveKbScope DELETEs /kb-scopes/:id on the AGENT key", () => {
    assert.match(
      INDEX_SRC,
      /async function archiveKbScope\(\{ project_id \}\)[\s\S]*?"DELETE",\s*`\/api\/v1\/kb-scopes\/\$\{project_id\}`,\s*null,\s*process\.env\.LOOPCTL_AGENT_KEY/,
      "archiveKbScope must DELETE /api/v1/kb-scopes/:id on the agent key",
    );
  });

  test("restoreKbScope POSTs /kb-scopes/:id/restore on the AGENT key", () => {
    assert.match(
      INDEX_SRC,
      /async function restoreKbScope\(\{ project_id \}\)[\s\S]*?"POST",\s*`\/api\/v1\/kb-scopes\/\$\{project_id\}\/restore`,[\s\S]*?process\.env\.LOOPCTL_AGENT_KEY/,
      "restoreKbScope must POST /api/v1/kb-scopes/:id/restore on the agent key",
    );
  });

  test("dispatch cases call archiveKbScope/restoreKbScope", () => {
    assert.match(INDEX_SRC, /case "archive_kb_scope":\s*\n\s*return await archiveKbScope\(args\);/);
    assert.match(INDEX_SRC, /case "restore_kb_scope":\s*\n\s*return await restoreKbScope\(args\);/);
  });
});

// ---------------------------------------------------------------------------
// #411 gap2 (PR B): recall_context (merged memory ∪ knowledge, one round-trip)
// ---------------------------------------------------------------------------

describe("#411 gap2: recall_context wiring", () => {
  test("TOOLS declares a recall_context tool requiring query", () => {
    assert.match(INDEX_SRC, /name: "recall_context",/, 'must declare a "recall_context" tool');
    assert.match(
      INDEX_SRC,
      /name: "recall_context",[\s\S]*?required: \["query"\],/,
      "the recall_context tool must require query",
    );
  });

  test("recallContext POSTs /api/v1/recall with query/project_id/limit on the agent key", () => {
    assert.match(
      INDEX_SRC,
      /async function recallContext\(\{ query, project_id, limit \}\) \{[\s\S]*?"POST",\s*\n\s*"\/api\/v1\/recall",[\s\S]*?LOOPCTL_AGENT_KEY/,
      "recallContext must POST /api/v1/recall on the agent key",
    );
    assert.match(INDEX_SRC, /const payload = \{ query \};\s*\n\s*if \(project_id\) payload\.project_id = project_id;/);
    assert.match(INDEX_SRC, /if \(limit != null\) payload\.limit = limit;/);
  });

  test("the recall_context dispatch case calls recallContext(args)", () => {
    assert.match(
      INDEX_SRC,
      /case "recall_context":\s*\n\s*return await recallContext\(args\);/,
      "the recall_context dispatch case must call recallContext(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// #411 gap3 (docs+MCP surface): memory_graduate (explicit memory→knowledge)
// ---------------------------------------------------------------------------

describe("#411 gap3: memory_graduate wiring", () => {
  test("TOOLS declares a memory_graduate tool requiring memory_id", () => {
    assert.match(INDEX_SRC, /name: "memory_graduate",/, 'must declare a "memory_graduate" tool');
    assert.match(
      INDEX_SRC,
      /name: "memory_graduate",[\s\S]*?required: \["memory_id"\],/,
      "the memory_graduate tool must require memory_id",
    );
  });

  test("memory_graduate declares a re_scope enum of inherit|global", () => {
    assert.match(
      INDEX_SRC,
      /name: "memory_graduate",[\s\S]*?re_scope: \{[\s\S]*?enum: \["inherit", "global"\],/,
      "the memory_graduate re_scope arg must be an enum of inherit|global",
    );
  });

  test("memoryGraduate POSTs /api/v1/memory/graduate with memory_id/re_scope on the agent key", () => {
    assert.match(
      INDEX_SRC,
      /async function memoryGraduate\(\{ memory_id, re_scope \}\) \{[\s\S]*?"POST",\s*\n\s*"\/api\/v1\/memory\/graduate",[\s\S]*?LOOPCTL_AGENT_KEY/,
      "memoryGraduate must POST /api/v1/memory/graduate on the agent key",
    );
    assert.match(INDEX_SRC, /const payload = \{ memory_id \};\s*\n\s*if \(re_scope\) payload\.re_scope = re_scope;/);
  });

  test("the memory_graduate dispatch case calls memoryGraduate(args)", () => {
    assert.match(
      INDEX_SRC,
      /case "memory_graduate":\s*\n\s*return await memoryGraduate\(args\);/,
      "the memory_graduate dispatch case must call memoryGraduate(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// #248 (mcp-02): knowledge_ingestion_jobs forwards limit/offset/since_days
// ---------------------------------------------------------------------------

describe("#248 mcp-02: knowledge_ingestion_jobs pagination (real ingestionJobsPath)", () => {
  test("forwards limit, offset, and since_days", () => {
    const url = new URL(`https://x${ingestionJobsPath({ limit: 10, offset: 20, since_days: 7 })}`);
    assert.equal(url.pathname, "/api/v1/knowledge/ingestion-jobs");
    assert.equal(url.searchParams.get("limit"), "10");
    assert.equal(url.searchParams.get("offset"), "20");
    assert.equal(url.searchParams.get("since_days"), "7");
  });

  test("omits params when none are supplied", () => {
    assert.equal(ingestionJobsPath(), "/api/v1/knowledge/ingestion-jobs");
    assert.equal(ingestionJobsPath({}), "/api/v1/knowledge/ingestion-jobs");
  });

  test("index.js knowledgeIngestionJobs uses ingestionJobsPath(args) + orch key, dispatch passes args", () => {
    assert.match(
      INDEX_SRC,
      /async function knowledgeIngestionJobs\(args = \{\}\) \{[\s\S]*?ingestionJobsPath\(args\)[\s\S]*?LOOPCTL_ORCH_KEY/,
      "knowledgeIngestionJobs must delegate to ingestionJobsPath(args) on the orch key",
    );
    assert.match(
      INDEX_SRC,
      /case "knowledge_ingestion_jobs":\s*\n\s*return await knowledgeIngestionJobs\(args\);/,
      "the knowledge_ingestion_jobs dispatch case must call knowledgeIngestionJobs(args)",
    );
  });
});

// ---------------------------------------------------------------------------
// US-26.7.1: public agent-rooted self-signup tool
// ---------------------------------------------------------------------------

describe("US-26.7.1: signup tool (agent-rooted, KB-tier self-signup)", () => {
  test("TOOLS declares a signup tool requiring name/slug/email", () => {
    assert.match(INDEX_SRC, /name: "signup",/, "TOOLS must declare a \"signup\" tool");
    assert.match(
      INDEX_SRC,
      /required: \["name", "slug", "email"\],/,
      "the signup tool must require name, slug, and email",
    );
  });

  test("signup() calls publicApiCall (no API key) against POST /api/v1/signup", () => {
    assert.match(
      INDEX_SRC,
      /async function signup\(\{ name, slug, email \}\) \{[\s\S]*?publicApiCall\(\s*"POST",\s*"\/api\/v1\/signup"/,
      "signup() must delegate to publicApiCall (not apiCall — no key exists yet) against POST /api/v1/signup",
    );
  });

  test("the signup dispatch case calls signup(args)", () => {
    assert.match(
      INDEX_SRC,
      /case "signup":\s*\n\s*return await signup\(args\);/,
      "the signup dispatch case must call signup(args)",
    );
  });

  test("publicApiCall never attaches an Authorization header", () => {
    const match = INDEX_SRC.match(
      /async function publicApiCall\(method, path, body\) \{[\s\S]*?\n}\n/,
    );
    assert.ok(match, "publicApiCall must be defined");
    assert.doesNotMatch(match[0], /Authorization/, "publicApiCall must not send an Authorization header");
  });
});

// ---------------------------------------------------------------------------
// Epic 28 (#179): per-tenant BYO LLM config + usage tools
// ---------------------------------------------------------------------------

describe("#179 BYO LLM: knowledge_llm_usage pagination (real llmUsagePath)", () => {
  test("forwards from, to, limit, and offset", () => {
    const url = new URL(
      `https://x${llmUsagePath({ from: "2026-01-01T00:00:00Z", to: "2026-02-01T00:00:00Z", limit: 10, offset: 20 })}`,
    );
    assert.equal(url.pathname, "/api/v1/knowledge/llm-usage");
    assert.equal(url.searchParams.get("from"), "2026-01-01T00:00:00Z");
    assert.equal(url.searchParams.get("to"), "2026-02-01T00:00:00Z");
    assert.equal(url.searchParams.get("limit"), "10");
    assert.equal(url.searchParams.get("offset"), "20");
  });

  test("omits params when none are supplied", () => {
    assert.equal(llmUsagePath(), "/api/v1/knowledge/llm-usage");
    assert.equal(llmUsagePath({}), "/api/v1/knowledge/llm-usage");
  });

  test("index.js knowledgeLlmUsage uses llmUsagePath(args) + orch key, dispatch passes args", () => {
    assert.match(
      INDEX_SRC,
      /async function knowledgeLlmUsage\(args = \{\}\) \{[\s\S]*?llmUsagePath\(args\)[\s\S]*?LOOPCTL_ORCH_KEY/,
      "knowledgeLlmUsage must delegate to llmUsagePath(args) on the orch key",
    );
    assert.match(
      INDEX_SRC,
      /case "knowledge_llm_usage":\s*\n\s*return await knowledgeLlmUsage\(args\);/,
      "the knowledge_llm_usage dispatch case must call knowledgeLlmUsage(args)",
    );
  });
});

describe("#179 BYO LLM: llm_config / set_llm_config use the USER key", () => {
  test("llm_config GETs the config with the EXACT user key (review #12)", () => {
    assert.match(
      INDEX_SRC,
      /async function llmConfig\(\) \{[\s\S]*?"\/api\/v1\/tenants\/me\/llm-config"[\s\S]*?LOOPCTL_USER_KEY[\s\S]*?exactKey: true/,
      "llmConfig must GET /tenants/me/llm-config with the EXACT user key (exactKey:true)",
    );
    assert.match(
      INDEX_SRC,
      /case "llm_config":\s*\n\s*return await llmConfig\(\);/,
      "the llm_config dispatch case must call llmConfig()",
    );
  });

  test("set_llm_config PATCHes with the EXACT user key (review #12, #13)", () => {
    assert.match(
      INDEX_SRC,
      /async function setLlmConfig\(\{[\s\S]*?"PATCH",\s*\n\s*"\/api\/v1\/tenants\/me\/llm-config",[\s\S]*?LOOPCTL_USER_KEY[\s\S]*?exactKey: true/,
      "setLlmConfig must PATCH /tenants/me/llm-config with the EXACT user key (exactKey:true)",
    );
    assert.match(
      INDEX_SRC,
      /case "set_llm_config":\s*\n\s*return await setLlmConfig\(args\);/,
      "the set_llm_config dispatch case must call setLlmConfig(args)",
    );
  });

  test("apiCall exactKey mode bypasses the global LOOPCTL_API_KEY override", () => {
    // exactKey:true must use the passed key verbatim (not resolveKey), so a secret
    // op never runs under a non-user global override (review #12).
    assert.match(
      INDEX_SRC,
      /const key = exactKey \? keyOverride : resolveKey\(keyOverride\);/,
      "apiCall must use the exact key (not resolveKey) when exactKey is true",
    );
  });
});

// ---------------------------------------------------------------------------
// #249 (mcp-03): defensive JSON parsing (REAL parseJsonResponseBody)
// ---------------------------------------------------------------------------

describe("#249 mcp-03: parseJsonResponseBody (shared with apiCall)", () => {
  test("valid JSON returns { parsed } (no error)", () => {
    const out = parseJsonResponseBody(
      JSON.stringify({ data: [1, 2, 3], meta: { total_count: 3 } }),
      200,
    );
    assert.equal(out.error, undefined);
    assert.deepEqual(out.parsed, { data: [1, 2, 3], meta: { total_count: 3 } });
  });

  test("empty body returns a structured error with the status (no throw)", () => {
    let out;
    assert.doesNotThrow(() => {
      out = parseJsonResponseBody("", 502);
    });
    assert.equal(out.error, true);
    assert.equal(out.status, 502);
    assert.match(out.body, /empty body/);
    assert.match(out.body, /HTTP 502/);
  });

  test("whitespace-only body is treated as empty", () => {
    const out = parseJsonResponseBody("   \n\t ", 503);
    assert.equal(out.error, true);
    assert.match(out.body, /empty body/);
  });

  test("invalid JSON returns a structured error with a raw-body snippet (no throw)", () => {
    let out;
    assert.doesNotThrow(() => {
      out = parseJsonResponseBody("<html>502 Bad Gateway</html>", 503);
    });
    assert.equal(out.error, true);
    assert.equal(out.status, 503);
    assert.match(out.body, /invalid\/empty JSON response from server/);
    assert.match(out.body, /HTTP 503/);
    assert.match(out.body, /502 Bad Gateway/);
  });

  test("long invalid body is truncated in the snippet", () => {
    const long = "x".repeat(1000);
    const out = parseJsonResponseBody(long, 500);
    assert.equal(out.error, true);
    assert.match(out.body, /\.\.\. \(truncated\)/);
    assert.ok(out.body.length < long.length, "snippet must be shorter than the raw body");
  });

  test("index.js apiCall delegates to parseJsonResponseBody and no longer calls response.json() unguarded", () => {
    assert.match(
      INDEX_SRC,
      /parseJsonResponseBody\(raw, response\.status\)/,
      "apiCall must parse the JSON branch via the shared parseJsonResponseBody",
    );
    assert.ok(
      !/responseBody = await response\.json\(\);/.test(INDEX_SRC),
      "index.js must not call response.json() unguarded",
    );
  });
});

// ---------------------------------------------------------------------------
// #730: knowledge_assert_conflict — registered, dispatched, and pointed at the
// assert endpoint rather than the resolve one
// ---------------------------------------------------------------------------

describe("#730: knowledge_assert_conflict wiring", () => {
  test("the tool is registered with evidence required", () => {
    assert.match(
      INDEX_SRC,
      /name: "knowledge_assert_conflict"/,
      "index.js must register the knowledge_assert_conflict tool",
    );
    assert.match(
      INDEX_SRC,
      /name: "knowledge_assert_conflict"[\s\S]*?required: \["source_article_id", "target_article_id", "evidence"\]/,
      "evidence must be a REQUIRED input — an assertion carries no similarity score, so " +
        "the argument is the whole evidence a reviewer judges",
    );
  });

  test("the dispatch case calls knowledgeAssertConflict", () => {
    assert.match(
      INDEX_SRC,
      /case "knowledge_assert_conflict":\s*\n\s*return await knowledgeAssertConflict\(args\);/,
      "a registered tool with no dispatch case is invisible at call time",
    );
  });

  test("it POSTs to the ASSERT endpoint with the agent key", () => {
    const body = functionSource("knowledgeAssertConflict");
    assert.match(body, /"POST"/);
    assert.match(
      body,
      /"\/api\/v1\/knowledge\/conflicts"/,
      "must post to /knowledge/conflicts — /knowledge/conflicts/resolve is the verdict path " +
        "and would 422 on an unflagged pair, which is the whole bug this closes",
    );
    assert.doesNotMatch(body, /conflicts\/resolve/);
    assert.match(body, /process\.env\.LOOPCTL_AGENT_KEY/);
  });

  test("optional fields are omitted rather than sent as undefined", () => {
    const body = functionSource("knowledgeAssertConflict");
    assert.match(body, /if \(classification\) payload\.classification = classification;/);
    assert.match(body, /if \(proposed_authoritative_article_id\)/);
  });

  // The completion path has to EXIST for the shipped client: the asserter cannot judge its
  // own pair, so if both tools forward the same key every asserted pair is unjudgeable
  // forever — in this session and every later one on the same config.
  test("knowledge_resolve_conflict prefers the orchestrator key over the asserting one", () => {
    const body = functionSource("knowledgeResolveConflict");
    assert.match(
      body,
      /process\.env\.LOOPCTL_ORCH_KEY \|\| process\.env\.LOOPCTL_AGENT_KEY/,
      "the verdict must go out on the orchestrator key when one is configured, or a pair " +
        "asserted with LOOPCTL_AGENT_KEY can never be resolved (409 self_asserted_conflict)",
    );
  });

  test("the tool description states what it does NOT grant", () => {
    // The two properties a caller will otherwise assume it bought: an assertion neither
    // retires the loser nor lets its asserter judge the pair. Both are refusals the server
    // enforces, so a description that omits them sends agents into a 409 they can't parse.
    const start = INDEX_SRC.indexOf('name: "knowledge_assert_conflict"');
    const description = INDEX_SRC.slice(start, start + 3000);
    assert.match(description, /self_asserted_conflict/);
    assert.match(description, /curated answers/);
  });
});
