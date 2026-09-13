/**
 * Story claim leases (loopctl #803/#810, MCP side under #809).
 *
 * A claim now carries a LEASE (`claimed_until`, default 24h, STORY_CLAIM_LEASE_SECONDS)
 * and a FENCE (`claim_epoch`, bumped by every claim and every release). A claim that is not
 * renewed before `claimed_until` is released back to `pending` under the agent still
 * working it. `renew_story_claim` is the MCP path to `POST /stories/:id/renew-claim`, and
 * `claimLeaseNotice` puts the epoch and the deadline at the top of a `claim_story` result so
 * the agent keeps the epoch the renewal needs.
 *
 * SINGLE SOURCE OF TRUTH. index.js injects `apiCall`; the unit suite runs this code with a
 * recording fake. The KEY is selected here, from the injected env, so the key a renewal
 * travels on is testable behaviour rather than a source pattern.
 *
 * Nothing is validated client-side beyond `story_id`: the server's 400 (missing or
 * non-integer epoch), 422 `not_claimed`, 409 `stale_claim_epoch` and 409 `not_claimant`
 * pass through unchanged, because each one tells the agent something different to do.
 */

export function renewClaimPath(storyId) {
  return `/api/v1/stories/${encodeURIComponent(storyId)}/renew-claim`;
}

/**
 * `POST /api/v1/stories/:id/renew-claim {claim_epoch}` on the AGENT key, the same key
 * `claim_story` uses. `claim_epoch` is forwarded exactly as given.
 */
export async function renewStoryClaim({ story_id, claim_epoch } = {}, { apiCall, env = process.env } = {}) {
  if (typeof story_id !== "string" || story_id.trim() === "") {
    return { error: true, status: 0, body: "`story_id` is required." };
  }
  return apiCall("POST", renewClaimPath(story_id), { claim_epoch }, env.LOOPCTL_AGENT_KEY);
}

/**
 * A leading line for a claim or renewal result naming the claim's epoch and lease, or null
 * when the server returned neither (an older loopctl, or an error).
 */
export function claimLeaseNotice(result) {
  const story = result && result.error !== true ? result.story : null;
  if (!story || !Number.isInteger(story.claim_epoch)) return null;

  const lease = story.claimed_until
    ? `claimed_until ${story.claimed_until}: renew with renew_story_claim before then, or the ` +
      "story is released back to pending under you."
    : "no lease (claimed_until is null), so it is never released automatically.";

  return (
    `CLAIM LEASE: claim_epoch ${story.claim_epoch}, ${lease} Keep claim_epoch; ` +
    "renew_story_claim requires it. A 409 stale_claim_epoch means the claim has ended: stop working it."
  );
}
