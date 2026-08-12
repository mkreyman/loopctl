/**
 * Leading notices for search results whose META carries something the agent must act on
 * (#658).
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
 * This mirrors the existing BYO-LLM `no_embedding_key` ACTION REQUIRED notice, which
 * already established that a meta-only disclosure is not enough to change behaviour.
 */

/** True when a result degraded to a fallback lane, whatever the cause. */
function isDegraded(meta) {
  return Boolean(meta && (meta.fallback === true || meta.degraded === true));
}

function resultCount(result) {
  if (!result || typeof result !== "object") return null;
  if (Array.isArray(result.data)) return result.data.length;
  if (Array.isArray(result.results)) return result.results.length;
  return null;
}

/**
 * Returns a notice string when a search DEGRADED, or null otherwise.
 *
 * The empty case gets the strong wording because it is the one that misleads: an empty
 * degraded response is indistinguishable from a genuine miss. A degraded response that
 * still returned rows gets a softer note — the results are real but the ranking was not
 * the one requested, so they may be incomplete.
 */
function degradedSearchNotice(result) {
  const meta = result && result.meta;
  if (!isDegraded(meta)) return null;

  // The BYO-key case already has its own, more specific ACTION REQUIRED notice; do not
  // stack two notices on one result.
  if (meta.fallback_reason === "no_embedding_key") return null;

  const reason = meta.fallback_reason || "unknown";
  const count = resultCount(result);

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

export { degradedSearchNotice, isDegraded };
