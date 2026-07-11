// Per-tenant generated Context Retriever tool runtime (US-30.5).
//
// index.js is a stdio entry point with top-level await (importing it boots the MCP
// server), so its handlers can't be imported by tests. This module extracts the
// generated-tools fetch / cache / dispatch runtime — the logic with real caching,
// TTL, negative-cache and error-classification edge cases — into a side-effect-free
// factory (like lib/http-helpers.js). index.js wires the SHIPPED `apiCall`, static
// tool names, and `toContent` into `createGeneratedToolsRuntime`, and the test suite
// exercises the SAME code, so a regression fails CI instead of silently passing
// against a hand-copied mirror.

import {
  retrieveToolsPath,
  retrieveEntityPath,
  specToMcpTool,
  buildRetrieveBody,
} from "./http-helpers.js";

export const GENERATED_TOOL_PREFIX = "cr_";

// ListTools is an init-time, agent-blocking call (Claude Code blocks on it during
// connection setup). So the generated-tools fetch uses BOTH a SHORT timeout and a
// NEGATIVE TTL: during any Context-Retriever backend slowness/outage the listing
// degrades to the static tool surface quickly, and a failed fetch is cached for a
// short window so subsequent ListTools calls do NOT each re-issue a blocking fetch
// before degrading (us_30.5.json technical_notes: "keep it cached/short-timeout and
// degrade to static on failure").
export const GENERATED_TOOLS_CACHE_TTL_MS = 30_000; // positive: last fetch succeeded
export const GENERATED_TOOLS_NEGATIVE_TTL_MS = 5_000; // negative: last fetch failed
export const GENERATED_TOOLS_FETCH_TIMEOUT_MS = 5_000; // short per-fetch AbortSignal budget

/**
 * Build a generated-tools runtime bound to injected dependencies. State (cache +
 * name->metadata map) is private to the returned closure.
 *
 * @param {{
 *   apiCall: (method: string, path: string, body: unknown, key: (string|undefined), opts?: object) => Promise<any>,
 *   agentKey: () => (string|undefined),
 *   staticToolNames?: Set<string>,
 *   toContent: (result: any) => object,
 *   now?: () => number,
 *   log?: (msg: string) => void,
 *   cacheTtlMs?: number,
 *   negativeTtlMs?: number,
 *   fetchTimeoutMs?: number,
 *   prefix?: string,
 * }} deps
 */
export function createGeneratedToolsRuntime({
  apiCall,
  agentKey,
  staticToolNames = new Set(),
  toContent,
  now = () => Date.now(),
  log = (msg) => console.error(msg),
  cacheTtlMs = GENERATED_TOOLS_CACHE_TTL_MS,
  negativeTtlMs = GENERATED_TOOLS_NEGATIVE_TTL_MS,
  fetchTimeoutMs = GENERATED_TOOLS_FETCH_TIMEOUT_MS,
  prefix = GENERATED_TOOL_PREFIX,
}) {
  // `ok` records the LAST fetch outcome so (a) the TTL guard applies the negative
  // TTL after a failure and (b) an unresolved CallTool can tell "temporarily
  // unavailable" from "genuinely unknown to this tenant". `tools`/`metadata` retain
  // the last KNOWN-GOOD listing so a failure degrades to it, never poisons it.
  let cache = { tools: [], fetchedAt: 0, ok: true };
  let metadataByName = new Map();

  function cacheFailure(at, message) {
    log(message);
    // Negative caching: stamp fetchedAt on failure (ok:false) WITHOUT touching the
    // retained tools/metadata, so subsequent calls within the negative-TTL window
    // return the degraded static surface instead of re-issuing a blocking fetch.
    cache = { tools: cache.tools, fetchedAt: at, ok: false };
    return cache.tools;
  }

  /**
   * Fetch the calling tenant's generated tool specs from GET /retrieve/tools and
   * map them to the MCP `{ name, description, inputSchema }` shape, (re)populating
   * the name->metadata map. On ANY failure this logs, negative-caches, and returns
   * the last-known (possibly empty) tools so ListTools degrades to static rather
   * than erroring (AC-30.5.1). Honors the positive/negative TTL unless `force`.
   *
   * @param {{ force?: boolean }} [opts]
   * @returns {Promise<Array<{ name: string, description: string, inputSchema: object }>>}
   */
  async function fetchGeneratedTools({ force = false } = {}) {
    const at = now();
    if (!force && cache.fetchedAt !== 0) {
      const ttl = cache.ok ? cacheTtlMs : negativeTtlMs;
      if (at - cache.fetchedAt < ttl) return cache.tools;
    }

    let result;
    try {
      result = await apiCall("GET", retrieveToolsPath(), null, agentKey(), {
        timeoutMs: fetchTimeoutMs,
      });
    } catch (err) {
      return cacheFailure(
        at,
        `loopctl: failed to fetch generated tools, degrading to static tools: ${err.message}`,
      );
    }

    if (result && result.error === true) {
      const detail = typeof result.body === "string" ? result.body : JSON.stringify(result.body);
      return cacheFailure(
        at,
        `loopctl: failed to fetch generated tools (HTTP ${result.status}), degrading to static tools: ${detail}`,
      );
    }

    const specs = result && Array.isArray(result.data) ? result.data : [];
    const tools = [];
    const metadata = new Map();
    for (const spec of specs) {
      const tool = specToMcpTool(spec);
      if (!tool) continue;
      // Defense-in-depth (US-30.5 review): the `cr_` prefix is a security-relevant
      // property the CallTool dispatcher relies on and the server is trusted to
      // enforce. Re-check it HERE so a non-cr_ spec (which would be listed but
      // UNCALLABLE) or one colliding with a STATIC tool name (which would shadow a
      // trusted built-in's description/inputSchema under tenant-controlled text —
      // a tool-confusion/description-spoofing vector) can never be listed or
      // registered under a trusted identity.
      if (!tool.name.startsWith(prefix) || staticToolNames.has(tool.name)) {
        log(
          `loopctl: dropping generated tool spec with invalid name "${tool.name}" ` +
            `(must be ${prefix}-prefixed and not collide with a static tool)`,
        );
        continue;
      }
      tools.push(tool);
      if (spec.metadata && typeof spec.metadata === "object") {
        metadata.set(tool.name, spec.metadata);
      }
    }

    metadataByName = metadata;
    cache = { tools, fetchedAt: at, ok: true };
    return tools;
  }

  /**
   * Resolve a generated tool name to its STRUCTURED dispatch metadata. On a miss
   * (name not in the current map) force ONE fresh fetch — bypassing the warm-TTL
   * short-circuit — so a tool created server-side since the last listing resolves
   * instead of being reported as authoritatively unknown.
   *
   * @param {string} name
   * @returns {Promise<object|null>}
   */
  async function resolveGeneratedToolMetadata(name) {
    if (metadataByName.has(name)) return metadataByName.get(name);
    await fetchGeneratedTools({ force: true });
    return metadataByName.get(name) || null;
  }

  /**
   * Generic dispatcher for a per-tenant generated tool. Resolves (entity, field,
   * operation) from STRUCTURED metadata (never by name-splitting — AC-30.5.2),
   * builds the US-30.4 body, and POSTs to /retrieve/:entity via the SAME `apiCall`
   * path as static reads (same auth + witness/STH — AC-30.5.4). An unresolvable
   * name after a forced refetch distinguishes a TRANSIENT backend failure (503,
   * retryable) from a name genuinely UNKNOWN to this tenant (404).
   *
   * @param {string} name
   * @param {object} [args]
   */
  async function callGeneratedTool(name, args = {}) {
    const metadata = await resolveGeneratedToolMetadata(name);
    if (metadata && typeof metadata.entity === "string" && typeof metadata.operation === "string") {
      const result = await apiCall(
        "POST",
        retrieveEntityPath(metadata.entity),
        buildRetrieveBody(metadata, args),
        agentKey(),
      );
      return toContent(result);
    }

    // Unresolved. If the forced refetch above FAILED (cache.ok === false), this is a
    // transient backend blip, not a definitive "unknown to this tenant" — say so, so
    // an agent retries instead of abandoning a valid tool.
    if (!metadata && !cache.ok) {
      return toContent({
        error: true,
        status: 503,
        body:
          `Generated tool "${name}" could not be resolved: the Context Retriever ` +
          `tool listing is temporarily unavailable (the tools fetch failed). Retry shortly.`,
      });
    }
    return toContent({
      error: true,
      status: 404,
      body: `Unknown tool: ${name}. No generated tool by that name is available to this tenant.`,
    });
  }

  return {
    fetchGeneratedTools,
    resolveGeneratedToolMetadata,
    callGeneratedTool,
    // Introspection seam for tests (not used by the server).
    cacheState: () => ({ ...cache }),
  };
}
