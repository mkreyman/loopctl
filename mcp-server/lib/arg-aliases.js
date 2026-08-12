/**
 * Argument-name aliases for MCP tool calls (#657).
 *
 * WHY THIS EXISTS. A catalogue of 1,932 real agent searches, mined from Claude session
 * transcripts across two machines, found that 86 `knowledge_search` calls — 8% of every
 * search call made — failed with `400 Query parameter 'q' is required`. 85 of those had
 * passed `query` instead of `q`, and most also passed `max_results` instead of `limit`.
 *
 * The queries were not the problem. They were the best queries in the corpus:
 *
 *     {"query": "custody halt tenant threshold byzantine detection", "max_results": "1"}
 *     {"query": "LCP-1 signed custody profile attestation enrollment owner key"}
 *     {"query": "dropping a legacy pgvector HNSW index shared_buffers eviction retirement"}
 *
 * Every one was discarded over a synonym. Agents reach for `query`/`max_results` because
 * that is what the surrounding ecosystem uses (WebSearch takes `query`; several MCP servers
 * take `max_results`), and no amount of tool-description wording reliably overrides that
 * habit — these calls were made by agents that had the schema in context.
 *
 * A search costs an embedding call and a turn of human attention. Refusing one over a
 * spelling is the worst trade available. Accept both.
 *
 * CANONICAL WINS. An explicit canonical value is never overwritten, so a caller passing both
 * `q` and `query` gets exactly what it asked for. Only a missing/blank canonical is filled.
 */

const ARG_ALIASES = {
  q: ["query", "search", "text"],
  limit: ["max_results", "maxResults", "top_k", "topK", "n"],
  article_id: ["articleId", "id"],
  project_id: ["projectId"],
  story_id: ["storyId"],
  since_days: ["sinceDays", "days"],
};

function isBlank(v) {
  return v === undefined || v === null || v === "";
}

/**
 * Returns a NEW args object with canonical keys filled in from any alias present.
 * Non-object input (null/undefined/array) is returned unchanged.
 */
function applyArgAliases(args) {
  if (!args || typeof args !== "object" || Array.isArray(args)) return args;

  const out = { ...args };

  for (const [canonical, aliases] of Object.entries(ARG_ALIASES)) {
    if (!isBlank(out[canonical])) continue;
    for (const alias of aliases) {
      if (!isBlank(out[alias])) {
        out[canonical] = out[alias];
        break;
      }
    }
  }

  // Some callers send a numeric arg as a string ("6"). Coerce so downstream validation and
  // the outbound query string both see a number rather than rejecting or double-encoding.
  if (typeof out.limit === "string" && /^\d+$/.test(out.limit.trim())) {
    out.limit = parseInt(out.limit.trim(), 10);
  }

  return out;
}

export { ARG_ALIASES, applyArgAliases };
