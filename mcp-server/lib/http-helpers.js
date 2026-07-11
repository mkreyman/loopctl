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
 * Path for `memory_list`, honoring limit/offset/include_superseded/all_subjects
 * (US-28.4). Routes through the shared `buildQuery` helper (rather than a local
 * `URLSearchParams` mirror) so the query-string construction is exercised by the
 * SAME code the server ships.
 *
 * @param {{ limit?: number, offset?: number, include_superseded?: boolean, all_subjects?: boolean }} [args]
 * @returns {string}
 */
export function memoryPath({ limit, offset, include_superseded, all_subjects } = {}) {
  return `/api/v1/memory${buildQuery([
    ["limit", limit],
    ["offset", offset],
    ["include_superseded", include_superseded],
    ["all_subjects", all_subjects],
  ])}`;
}

/**
 * Path for the Context Retriever generated-tool specs (US-30.5, US-30.4).
 * The literal `/retrieve/tools` route is fixed and carries no query params — the
 * calling tenant is resolved SERVER-SIDE from the API key, never from the client,
 * so there is nothing for the client to parameterize here (AC-30.5.3/AC-30.5.4).
 *
 * @returns {string}
 */
export function retrieveToolsPath() {
  return "/api/v1/retrieve/tools";
}

/**
 * Path for executing a generated tool against a single entity (US-30.5, US-30.4).
 * `entity` comes from the STRUCTURED metadata on a generated tool spec (never by
 * splitting the tool name — entity/field names contain underscores), so it is
 * encoded defensively.
 *
 * @param {string} entity
 * @returns {string}
 */
export function retrieveEntityPath(entity) {
  return `/api/v1/retrieve/${encodeURIComponent(entity)}`;
}

/**
 * Map a raw generated-tool spec (as returned by GET /api/v1/retrieve/tools —
 * `{ name, description, input_schema, metadata }`) into the MCP tool shape the
 * ListTools handler must return (`{ name, description, inputSchema }`). The server
 * emits snake_case `input_schema`; MCP expects camelCase `inputSchema`.
 *
 * Returns null for a malformed spec (no string `name`) so a single bad entry is
 * skipped rather than corrupting the whole listing.
 *
 * @param {{ name?: unknown, description?: unknown, input_schema?: unknown }} spec
 * @returns {{ name: string, description: string, inputSchema: object } | null}
 */
export function specToMcpTool(spec) {
  if (!spec || typeof spec.name !== "string") return null;
  return {
    name: spec.name,
    description: typeof spec.description === "string" ? spec.description : "",
    inputSchema:
      spec.input_schema && typeof spec.input_schema === "object"
        ? spec.input_schema
        : { type: "object", properties: {} },
  };
}

/**
 * Build the POST /api/v1/retrieve/:entity request body for a generated-tool call
 * from the tool's STRUCTURED dispatch metadata (US-30.2 — `{ entity, field,
 * operation }`) plus the caller's runtime `args`. The (entity, field, operation)
 * come from metadata, NOT from splitting the tool name (AC-30.5.2), so entity and
 * field names containing underscores dispatch unambiguously.
 *
 * The body shape matches the US-30.4 controller (`RetrieveRequest`): `op` selects
 * the operation; `filter` carries `field` + `value`, `search` carries `query`;
 * `limit`/`offset` pagination pass through when present. Nullish args are omitted
 * so unset params never override server defaults.
 *
 * Filter-value sourcing (US-30.5 fix): the US-30.2 ToolGenerator emits the filter
 * tool's input_schema with the value argument under the FIELD-NAME key (e.g.
 * `{status}`, `required: ["status"]`) — there is NO `value` property. A
 * schema-compliant agent therefore calls `cr_filter_project_by_status({status:
 * "active"})`. So read the value from the field-named arg FIRST, falling back to a
 * literal `value` arg (the shape the controller also accepts) for tolerance.
 * Reading only `args.value` would drop every real agent-supplied filter value and
 * dispatch an empty filter that silently returns zero rows.
 *
 * @param {{ entity: string, field?: string|null, operation: string }} metadata
 * @param {Record<string, unknown>} [args]
 * @returns {object}
 */
export function buildRetrieveBody(metadata, args = {}) {
  const body = { op: metadata.operation };

  if (metadata.operation === "filter") {
    body.field = metadata.field;
    const fieldArg = metadata.field != null ? args[metadata.field] : undefined;
    const filterValue = fieldArg !== undefined ? fieldArg : args.value;
    if (filterValue !== undefined) body.value = filterValue;
  } else if (metadata.operation === "search") {
    if (args.query !== undefined) body.query = args.query;
  }

  if (args.limit != null) body.limit = args.limit;
  if (args.offset != null) body.offset = args.offset;

  return body;
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
