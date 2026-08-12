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

// BIDIRECTIONAL BY DESIGN. The 86 failures were not agents guessing wrong — this MCP
// server's own surface is inconsistent, and `knowledge_search` is the odd one out:
//
//     query  ->  knowledge_hybrid_search, knowledge_context, memory_recall, recall_context
//     q      ->  knowledge_search        (alone)
//
// Four sibling tools take `query`; the single most-used tool takes `q`. An agent that
// learns `query` from any neighbour and applies it to knowledge_search gets a 400. So the
// mapping runs BOTH ways: whichever spelling arrives, the other is filled in, and each tool
// reads the key it declares. Handlers select named arguments when building their request,
// so the extra key is inert rather than forwarded.
//
// Renaming knowledge_search's parameter instead would be a breaking change for every
// existing caller that already passes `q` correctly. Accepting both costs nothing.
// ONLY OBSERVED ALIASES. This table lists what agents were MEASURED to send, nothing more.
// The first draft also mapped `search`, `text`, `top_k`, `topK`, `n` and the camelCase id
// spellings — all invented, none seen in the data — and the drift guard below immediately
// caught two of them colliding with real parameters that mean something else entirely:
// four tools declare `query` as their own canonical, and `memory_remember` declares `text`
// for the CONTENT of a memory. Aliasing that into `q` would have copied a memory's body
// into a search-query slot.
//
// A speculative alias is not free: it is a silent rename of somebody else's parameter.
// Add one only when a real failing call is observed to need it.
const ARG_ALIASES = {
  q: ["query"],
  query: ["q"],
  limit: ["max_results"],
  max_results: ["limit"],
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
