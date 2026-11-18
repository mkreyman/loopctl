/**
 * `chg_ledger_summary` (loopctl US-50.6): the chg audit questions the /chg dashboard answers,
 * for a session with no browser — `GET /api/v1/chg_ledger/summary`.
 *
 * Gate outcomes per day, the fallback rate and its reasons, selection quality and misses,
 * time per gate phase, flaky tests, runner samples, merged-PR review outcomes, and changes
 * flagged gap or stale; computed server-side by the same functions the page renders.
 *
 * A READ, `role: :agent` with the hierarchy, so any role's key clears the gate and nothing is
 * pinned: the handler passes LOOPCTL_AGENT_KEY as an override, so `resolveKey`'s order holds
 * (LOOPCTL_API_KEY when set, else LOOPCTL_AGENT_KEY, else LOOPCTL_ORCH_KEY).
 */

export const MAX_PERIOD_DAYS = 90;

const DAY_MS = 86_400_000;

function refuse(body) {
  return { error: true, status: 0, body };
}

function parseTime(value) {
  if (typeof value !== "string" || value === "") return null;
  const ms = Date.parse(value);
  return Number.isNaN(ms) ? NaN : ms;
}

/** `GET /api/v1/chg_ledger/summary`, with the optional `repo`, `host`, `since`, `until`. */
export async function chgLedgerSummary(args = {}, { apiCall, now = Date.now } = {}) {
  const { repo, host, since, until } = args;

  for (const [name, value] of [
    ["repo", repo],
    ["host", host],
  ]) {
    if (value !== undefined && value !== null && typeof value !== "string") {
      return refuse(`\`${name}\` must be a string.`);
    }
  }

  const sinceMs = parseTime(since);
  const untilMs = parseTime(until);

  if (Number.isNaN(sinceMs)) return refuse("`since` must be an ISO 8601 timestamp.");
  if (Number.isNaN(untilMs)) return refuse("`until` must be an ISO 8601 timestamp.");

  // Mirrors the server's defaults only to refuse locally what it would refuse anyway; the
  // server stays the judge.
  const end = untilMs ?? now();
  const start = sinceMs ?? end - 7 * DAY_MS;

  if (start >= end) return refuse("`since` must be before `until`.");
  if (end - start > MAX_PERIOD_DAYS * DAY_MS) {
    return refuse(`The period may be at most ${MAX_PERIOD_DAYS} days (since to until).`);
  }

  const qs = new URLSearchParams();
  for (const [name, value] of [
    ["repo", repo],
    ["host", host],
    ["since", since],
    ["until", until],
  ]) {
    if (typeof value === "string" && value !== "") qs.set(name, value);
  }

  const query = qs.toString();
  return apiCall("GET", `/api/v1/chg_ledger/summary${query ? `?${query}` : ""}`, null);
}
