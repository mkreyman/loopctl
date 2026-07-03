// Pure, importable HTTP helpers shared by index.js and the test suite.
//
// index.js is a stdio entry point with top-level await (importing it would boot
// the MCP server), so it cannot be imported directly by tests. Extracting the
// logic that actually had bugs — query-string building for the paginated tools
// and the defensive JSON parse in apiCall — into this side-effect-free module
// gives BOTH index.js and the tests a single source of truth. The tests exercise
// the SAME code the server ships, so a regression in this logic fails CI instead
// of silently passing against a hand-copied mirror.

/**
 * Build a `?a=b&c=d` query string from an array of [key, value] pairs. Skips
 * null/undefined values (so unset params are omitted) and stringifies the rest.
 * Returns "" when nothing is set.
 *
 * @param {Array<[string, unknown]>} pairs
 * @returns {string}
 */
export function buildQuery(pairs) {
  const params = new URLSearchParams();
  for (const [key, value] of pairs) {
    if (value != null) params.set(key, String(value));
  }
  const qs = params.toString();
  return qs ? `?${qs}` : "";
}

/**
 * Path for `list_projects`, honoring page/page_size (#247, mcp-01).
 *
 * @param {{ page?: number, page_size?: number }} [args]
 * @returns {string}
 */
export function projectsPath({ page, page_size } = {}) {
  return `/api/v1/projects${buildQuery([
    ["page", page],
    ["page_size", page_size],
  ])}`;
}

/**
 * Path for `knowledge_ingestion_jobs`, honoring limit/offset/since_days
 * (#248, mcp-02).
 *
 * @param {{ limit?: number, offset?: number, since_days?: number }} [args]
 * @returns {string}
 */
export function ingestionJobsPath({ limit, offset, since_days } = {}) {
  return `/api/v1/knowledge/ingestion-jobs${buildQuery([
    ["limit", limit],
    ["offset", offset],
    ["since_days", since_days],
  ])}`;
}

/**
 * Path for `knowledge_llm_usage`, honoring from/to/limit/offset (Epic 28, #179).
 *
 * @param {{ from?: string, to?: string, limit?: number, offset?: number }} [args]
 * @returns {string}
 */
export function llmUsagePath({ from, to, limit, offset } = {}) {
  return `/api/v1/knowledge/llm-usage${buildQuery([
    ["from", from],
    ["to", to],
    ["limit", limit],
    ["offset", offset],
  ])}`;
}

/**
 * Defensively parse the raw text body of a JSON-content-type HTTP response
 * (#249, mcp-03).
 *
 * A JSON content-type header is no guarantee of a well-formed body: a transient
 * Fly edge 502/503 or a truncated response can arrive with the JSON header but an
 * empty or non-JSON body, which makes a bare `response.json()` throw an unhandled
 * exception. This turns that into a STRUCTURED error the MCP tool layer already
 * understands (`{ error: true, status, body }`), including the HTTP status and a
 * raw-body snippet for debugging.
 *
 * @param {string} rawText - the response body as text
 * @param {number} status - the HTTP status code
 * @returns {{ parsed: unknown } | { error: true, status: number, body: string }}
 *   `{ parsed }` on success, or a structured error object on empty/invalid JSON.
 */
export function parseJsonResponseBody(rawText, status) {
  if (rawText.trim() === "") {
    return {
      error: true,
      status,
      body: `invalid/empty JSON response from server (HTTP ${status}): empty body`,
    };
  }
  try {
    return { parsed: JSON.parse(rawText) };
  } catch {
    const snippet =
      rawText.length > 200 ? `${rawText.slice(0, 200)}... (truncated)` : rawText;
    return {
      error: true,
      status,
      body: `invalid/empty JSON response from server (HTTP ${status}): ${snippet}`,
    };
  }
}
