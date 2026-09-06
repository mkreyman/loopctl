/**
 * Leading notices for search results whose META carries something the agent must act on
 * (#658), now driven by the uniform tool-outcome envelope.
 *
 * THE DEFECT THIS FIXES. When semantic ranking is unavailable the server degrades to
 * keyword-only and says so LOUDLY — `meta.fallback: true`, `meta.degraded: true`,
 * `meta.fallback_reason`, plus telemetry and a server-side warning log. The degradation is
 * not silent at the server. It is silent at the CLIENT: agents do not read `meta`.
 *
 * Measured across real session transcripts on two machines: every degraded response that
 * came back empty was treated by the receiving agent as "the knowledge base has nothing".
 * It is a low-volume failure (roughly a dozen in ~1,900 searches) and a totally deceptive
 * one — and it lands hardest on the BEST queries, because the keyword fallback lane uses
 * AND semantics, so a long specific query is the most likely to match nothing at all.
 *
 * The remedy the agent needs is the opposite of the obvious one: do NOT rephrase. Different
 * words cannot fix a provider timeout. Retry the SAME query.
 *
 * WHAT `meta.outcome` ADDS. The knowledge, memory and corpus RETRIEVAL responses (plus the
 * `knowledge_list` enumeration path) now carry one of `success | empty | degraded |
 * fallback | error`, so the notice no longer has to infer the class from a handful of
 * per-surface flag names. Three classes get a notice, and they get DIFFERENT ones because
 * the remedies differ:
 *
 *   - `fallback` — the semantic lane died, keyword-only was served. Retry the SAME query.
 *   - `degraded` — a half was shed or capacity-limited. WAIT, then retry. Retrying at once
 *     goes straight back into the same closed gate, which is why this is not worded as a
 *     fallback. One cause is STANDING rather than transient (`ann_iterative_scan_unavailable`)
 *     and gets a remedy that does not prescribe a wait no wait can clear.
 *   - `error`    — the retrieval never ran; the empty envelope is a placeholder and says
 *     NOTHING about what the corpus holds.
 *
 * `empty` and `success` get NO notice on purpose. A notice on every ordinary zero-result
 * search is noise, and noise teaches agents to ignore the channel — the exact fate of the
 * `meta` fields this exists to replace. The distinction the agent needs is still on the
 * wire: the rendered JSON carries `meta.outcome: "empty"` next to a `degraded` one that
 * arrives with a shouting banner above it.
 *
 * This mirrors the existing BYO-LLM `no_embedding_key` ACTION REQUIRED notice, which
 * already established that a meta-only disclosure is not enough to change behaviour.
 */

/** The server's published vocabulary (LoopctlWeb.Outcome). */
const OUTCOMES = ["success", "empty", "degraded", "fallback", "error"];

/** True when a result degraded to a fallback lane, whatever the cause. */
function isDegraded(meta) {
  return Boolean(meta && (meta.fallback === true || meta.degraded === true));
}

/**
 * The server-declared outcome, or null when this response predates the envelope.
 *
 * Validated against the published list rather than passed through: an unrecognised value
 * means a server newer than this client, and inventing a notice for a class we do not
 * understand is worse than falling back to the flag heuristics below.
 */
function outcomeOf(result) {
  const value = result && result.meta && result.meta.outcome;
  return OUTCOMES.includes(value) ? value : null;
}

function resultCount(result) {
  if (!result || typeof result !== "object") return null;
  if (Array.isArray(result.data)) return result.data.length;
  if (Array.isArray(result.results)) return result.results.length;
  return null;
}

/**
 * The most specific bounded tag the response names, or a synthesised one.
 *
 * Every surface publishes its cause under its own key; this picks whichever is present so
 * the notice can NAME the cause. An unnamed degradation is much weaker advice — "something
 * was short" does not tell an agent whether to wait or to reconfigure.
 */
function reasonOf(meta) {
  const named =
    meta.fallback_reason ||
    meta.degraded_reason ||
    meta.reason ||
    meta.semantic_unavailable_reason ||
    meta.keyword_unavailable_reason;

  if (typeof named === "string" && named !== "") return named;
  if (meta.semantic_under_filled === true) return "semantic_under_filled";
  if (meta.ann_iterative_scan === "unavailable") return "ann_iterative_scan_unavailable";
  return "unspecified";
}

function fallbackNotice(reason, count) {
  if (count === 0) {
    return (
      `outcome: fallback — DEGRADED SEARCH, THIS IS NOT "NO RESULTS". Semantic ranking ` +
      `was unavailable (${reason}), so this ran keyword-only, and the keyword lane ` +
      `requires ALL terms to match — a long or specific query returns nothing even when ` +
      `the answer exists. Do NOT conclude the knowledge base lacks this, and do NOT ` +
      `rephrase: different words cannot fix a provider failure. RETRY THE SAME QUERY.`
    );
  }

  return (
    `outcome: fallback — PARTIAL SEARCH. Semantic ranking was unavailable (${reason}), so ` +
    `these are keyword-only matches and may be incomplete. Retry the same query for full ` +
    `ranking.`
  );
}

/**
 * A degradation that WAITING cannot clear, so the notice must not prescribe a wait.
 *
 * `ann_iterative_scan: "unavailable"` means the deployed pgvector ran the vector read
 * without the iterative scan the operator enabled, and the tenant filter was applied
 * after a single index batch — so the page may be short. The conclusive cause (pgvector
 * < 0.8, or the extension absent) stands until the extension is upgraded; retrying
 * re-runs the identical starved scan and burns a heavy read for nothing.
 */
const STANDING_REASON = "ann_iterative_scan_unavailable";

function degradedNotice(reason, count) {
  if (reason === STANDING_REASON) {
    const scope = count === 0 ? `THIS IS NOT "NO RESULTS"` : `PARTIAL RESULTS`;

    return (
      `outcome: degraded — ${scope}. The vector read ran without pgvector's iterative ` +
      `scan (${reason}), so it may have returned FEWER rows than match and its absences ` +
      `prove nothing. Retrying re-runs the same scan and does NOT clear this — it is a ` +
      `standing backend condition an operator has to fix. Use what you got, widen the ` +
      `filters, or reach for a non-vector route (knowledge_list, knowledge_heat_index).`
    );
  }

  if (count === 0) {
    return (
      `outcome: degraded — THIS IS NOT "NO RESULTS". A half of this retrieval was shed or ` +
      `capacity-limited (${reason}), so the corpus was never fully read. Do NOT conclude ` +
      `the knowledge base lacks this, and do NOT rephrase — the wording had no part in ` +
      `it. WAIT a few seconds, then RETRY THE SAME QUERY; an immediate retry goes back ` +
      `into the same closed gate.`
    );
  }

  return (
    `outcome: degraded — PARTIAL RESULTS. A half was shed or capacity-limited ` +
    `(${reason}), so this set may be SHORT and its absences prove nothing. Wait a few ` +
    `seconds, then retry the same query for the full set.`
  );
}

function errorNotice(reason) {
  return (
    `outcome: error — THE RETRIEVAL DID NOT RUN (${reason}); this empty envelope was ` +
    `served in its place. It says NOTHING about what the knowledge base holds. Fix the ` +
    `request, then retry.`
  );
}

/**
 * Returns a notice string when a search needs one, or null otherwise.
 *
 * Prefers the server-declared `meta.outcome`; falls back to the pre-envelope flag
 * heuristics so an older server still gets the #658 notice it used to.
 *
 * The zero-result cases get the strong wording because they are the ones that mislead: an
 * empty degraded response is indistinguishable from a genuine miss. A degraded response
 * that still returned rows gets a softer note — the results are real but the retrieval was
 * not the one requested, so they may be incomplete.
 */
function degradedSearchNotice(result) {
  const meta = result && result.meta;
  if (!meta || typeof meta !== "object") return null;

  // The BYO-key case already has its own, more specific ACTION REQUIRED notice; do not
  // stack two notices on one result.
  if (meta.fallback_reason === "no_embedding_key") return null;

  const count = resultCount(result);
  const outcome = outcomeOf(result);

  if (outcome) {
    switch (outcome) {
      case "fallback":
        return fallbackNotice(reasonOf(meta), count);
      case "degraded":
        return degradedNotice(reasonOf(meta), count);
      case "error":
        return errorNotice(reasonOf(meta));
      default:
        // success / empty — silence is the signal, see the module header.
        return null;
    }
  }

  if (!isDegraded(meta)) return null;

  // Pre-envelope server: one class, the historical wording, and no `outcome:` prefix to
  // claim a classification the server never made.
  const reason = meta.fallback_reason || "unknown";

  if (count === 0) {
    return (
      `DEGRADED SEARCH — THIS IS NOT "NO RESULTS". Semantic ranking was unavailable ` +
      `(${reason}), so this ran keyword-only, and the keyword lane requires ALL terms to ` +
      `match — a long or specific query returns nothing even when the answer exists. ` +
      `Do NOT conclude the knowledge base lacks this, and do NOT rephrase: different ` +
      `words cannot fix a provider failure. RETRY THE SAME QUERY.`
    );
  }

  return (
    `PARTIAL SEARCH — semantic ranking was unavailable (${reason}), so these are ` +
    `keyword-only matches and may be incomplete. Retry the same query for full ranking.`
  );
}

export { degradedSearchNotice, isDegraded, outcomeOf, OUTCOMES };
