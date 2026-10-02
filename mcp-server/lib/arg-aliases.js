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

import { isBlank } from "./required-args.js";

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
//
// A BIDIRECTIONAL FILL IS NOT A BIDIRECTIONAL RESCUE. Because a blank canonical is filled
// from whichever spelling arrived, a perfectly correct `knowledge_search` call carrying `q`
// ALSO gets `query` populated. Counting that as a rescue made the metric count normal
// traffic — far more often than real rescues — so it could not support the decision it was
// built to inform. `declared` (below) is the tool's own parameter list: a rescue is counted
// only when the key the HANDLER READS was blank and the alias supplied it.
//
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
//
// `max_results` has NO reverse entry on purpose: no tool declares it, so filling it from
// `limit` rescued nothing and merely put a stderr write on the hot path of every call that
// paginated correctly.
const ARG_ALIASES = {
  q: ["query"],
  query: ["q"],
  limit: ["max_results"],
};

// TOOL-SCOPED aliases, keyed by tool name. `id` cannot go in the global table above:
// memory_forget and others declare `id` as their own parameter, and the drift guard refuses
// it there. It is also scoped to ONE tool on purpose. The evidence below is about reads, and
// the same alias on knowledge_archive or knowledge_delete would turn a harmless miss into a
// terminal write against whatever id was copied from the wrong result.
//
// `article_id <- id` is measured, not guessed: 17 of 96 `knowledge_get` calls in this
// machine's transcripts (2026-10-01) passed `{"id": ...}`, the key every search result
// carries its id under. With no `article_id` the server asked for `/api/v1/articles/undefined`
// and answered 404, which the agent read as "the article is gone": all 30 knowledge_get
// 404s in loopctl's production logs for 2026-09-25..30 were that request, against 38 of 38
// reads that carried a real id and succeeded.
const TOOL_SCOPED_ALIASES = {
  knowledge_get: { article_id: ["id"] },
};


/**
 * Returns a NEW args object with canonical keys filled in from any alias present.
 * Non-object input (null/undefined/array) is returned unchanged.
 *
 * `declared` is the set/array of parameter names the CALLED TOOL actually declares. When
 * supplied, only a fill of a declared key is reported as a rescue — the rest are inert
 * conveniences. Omit it and every fill is reported (the conservative default for a tool
 * whose schema is not known, e.g. the per-tenant `cr_*` tools).
 */
function applyArgAliases(args, onAliasUsed, declared, toolName) {
  if (!args || typeof args !== "object" || Array.isArray(args)) return args;

  const out = { ...args };
  const declaredSet = declared ? new Set(declared) : null;

  for (const [canonical, aliases] of Object.entries(ARG_ALIASES)) {
    if (!isBlank(out[canonical])) continue;
    for (const alias of aliases) {
      if (!isBlank(out[alias])) {
        out[canonical] = out[alias];
        // Report every real rescue. Aliasing treats the SYMPTOM — the real defect is that
        // the tool surface spells the same parameter three ways (`q`, `query`, `topic`). If
        // the rescue is invisible, the inconsistency costs nothing measurable and never gets
        // fixed, and the alias table quietly becomes load-bearing forever. Counting it
        // keeps the residual cost on the books — which only works if the count is of calls
        // that WOULD HAVE FAILED, hence the `declared` gate.
        const rescued = declaredSet === null || declaredSet.has(canonical);
        if (rescued && typeof onAliasUsed === "function") {
          try {
            onAliasUsed({ canonical, alias });
          } catch {
            // Telemetry must never break a tool call.
          }
        }
        break;
      }
    }
  }

  const scoped = (toolName && Object.hasOwn(TOOL_SCOPED_ALIASES, toolName) && TOOL_SCOPED_ALIASES[toolName]) || {};
  if (declaredSet !== null) {
    for (const [canonical, aliases] of Object.entries(scoped)) {
      if (!declaredSet.has(canonical) || !isBlank(out[canonical])) continue;
      const alias = aliases.find((a) => !declaredSet.has(a) && !isBlank(out[a]));
      if (alias === undefined) continue;
      out[canonical] = out[alias];
      if (typeof onAliasUsed === "function") {
        try {
          onAliasUsed({ canonical, alias });
        } catch {
          // Telemetry must never break a tool call.
        }
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

export { ARG_ALIASES, TOOL_SCOPED_ALIASES, applyArgAliases };
