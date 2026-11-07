/**
 * `agent_outcomes` (loopctl US-48.12): an agent spec's track record from the run-outcome
 * ledger — `GET /api/v1/agent_specs/:spec_id/outcomes`.
 *
 * Per spec version, newest first: how many dispatches were recorded in the window, and how
 * many succeeded, were overridden by a human, or exhausted their budget, with the median
 * elapsed seconds and turns. Every figure is from an event loopctl recorded, never session
 * text.
 *
 * A READ, `role: :agent` with the hierarchy, so any role's key clears the gate and nothing is
 * pinned: the handler passes LOOPCTL_AGENT_KEY as an override, so `resolveKey`'s order holds
 * (LOOPCTL_API_KEY when set, else LOOPCTL_AGENT_KEY, else LOOPCTL_ORCH_KEY).
 */

const SPEC_ID = /^[a-z][a-z0-9_]{0,63}$/;

export const MAX_WINDOW_DAYS = 365;

function refuse(body) {
  return { error: true, status: 0, body };
}

export function agentOutcomesPath(specId) {
  return `/api/v1/agent_specs/${encodeURIComponent(specId)}/outcomes`;
}

/** `GET /api/v1/agent_specs/:spec_id/outcomes`, optionally `?window_days=N`. */
export async function agentOutcomes({ spec_id, window_days } = {}, { apiCall } = {}) {
  if (typeof spec_id !== "string" || !SPEC_ID.test(spec_id)) {
    return refuse(
      "`spec_id` is required: an agent spec id, lower-case (e.g. `triage`, `implement`, " +
        "`reply_draft`).",
    );
  }

  if (
    window_days !== undefined &&
    window_days !== null &&
    !(Number.isInteger(window_days) && window_days >= 1 && window_days <= MAX_WINDOW_DAYS)
  ) {
    return refuse(`\`window_days\` must be an integer from 1 to ${MAX_WINDOW_DAYS}.`);
  }

  const qs = Number.isInteger(window_days) ? `?window_days=${window_days}` : "";
  return apiCall("GET", `${agentOutcomesPath(spec_id)}${qs}`, null);
}
