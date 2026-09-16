/**
 * `revoke_dispatch` — `POST /api/v1/dispatches/:id/revoke`.
 *
 * ## The defect it exists for
 *
 * `Loopctl.Dispatches.revoke/2` had no route and no tool, so nothing outside the app
 * could call it. That made a stranded ephemeral key unfixable rather than merely
 * inconvenient, because of an invariant two layers down:
 *
 * `api_keys_one_role_per_agent_idx` is a PARTIAL UNIQUE index over
 * `(tenant_id, agent_id, role)` with the predicate
 * `revoked_at IS NULL AND role NOT IN ('user','superadmin')`. It CANNOT also test
 * `expires_at` — Postgres requires a partial-index predicate to be IMMUTABLE and
 * `now()` is STABLE — so the index's idea of "active" is `revoked_at IS NULL` while the
 * auth pipeline's is `revoked_at IS NULL AND expires_at > now()`. A key whose session
 * died is unusable for authentication and STILL OCCUPIES its agent's slot, so the next
 * mint for that agent at that role is refused
 * `422 agent already has an active key with this role`.
 *
 * Measured on story `d9975b31` (2026-09-15): `place_dispatch` answered exactly that 422
 * and wrote nothing, because a session dispatch from an earlier attempt was never
 * revoked. Nothing an operator could reach would clear it before its TTL.
 *
 * ## WHAT IT REVOKES — say this out loud before calling it
 *
 * The dispatch AND EVERY DESCENDANT, plus the ephemeral api_key each one minted. That
 * is `Dispatches.revoke/2`'s own semantics (its query is
 * `d.id == ^dispatch_id or ^dispatch_id in d.lineage_path`), not something this tool
 * adds. Revoking a tree's root revokes the tree.
 *
 * ## WHAT IT DOES NOT DO
 *
 * It does not clear `stories.implementer_dispatch_id`. That field is custody
 * provenance: loopctl resolves it with `Dispatches.get_dispatch/2`, which reads a
 * REVOKED row exactly as it reads a live one, so `verify` / `report` /
 * `review-complete` compare the same lineage afterwards. Revoking kills the credential
 * and changes no custody verdict.
 *
 * ## REFUSALS
 *
 * - `403 insufficient_role` — the endpoint is `role: :orchestrator` WITH the hierarchy,
 *   so an orchestrator, user or superadmin key passes and an agent key does not. It is
 *   NOT `exact_role`, so this tool pins no particular env var: whichever key `apiCall`
 *   resolves is sent, exactly as `dispatch` does at the same gate.
 * - `403 custody_tier_required` — an agent-rooted tenant. Such a tenant cannot mint a
 *   dispatch either, so it has none to revoke.
 * - `403 dispatch_outside_caller_lineage` — THE LINEAGE CEILING. A dispatch may only be
 *   revoked by a caller it descends from, because the revoke cascades: without it one
 *   principal could take down another's whole tree, and an implementer could prune the
 *   pool `select_verifier/3` draws from (it admits only dispatches that are
 *   `revoked_at IS NULL AND expires_at > now`) until the verifier it prefers is the one
 *   left. The tenant's `user`-role operator key — one no dispatch minted — may revoke
 *   anywhere in its tenant. The refusal carries `remediation.your_dispatch_id` when the
 *   caller has one.
 * - `503 tenant_halted` — a custody halt suspends this route, like dispatch minting.
 * - `404` — no such dispatch in your tenant. Another tenant's id answers 404 too.
 *
 * ## IDEMPOTENT
 *
 * An already-revoked dispatch answers 200 with `revoked_count: 0` and its ORIGINAL
 * `revoked_at`; the revoke statement only touches rows that are `revoked_at IS NULL`.
 * Retrying after a timeout is safe and never rewrites a revocation timestamp.
 *
 * ## EXPIRY IS SWEPT, SO REACH FOR THIS ONLY WHEN WAITING IS TOO SLOW
 *
 * `Loopctl.Workers.RevokeExpiredDispatchesWorker` (cron, every minute) revokes a
 * dispatch and its key once `expires_at` has passed, and
 * `RevokeExpiredApiKeysWorker` (every five minutes) catches a key minted with no
 * dispatch behind it. So a stranded credential DOES clear itself — at its TTL, which for
 * a placement session dispatch is four hours. This tool is for not waiting.
 * `force_unclaim_story` also revokes the session dispatch of the story it frees, so on a
 * parked story that is the one call to make.
 */

const MISSING_ID =
  "`dispatch_id` is required: the dispatch to revoke, from `mcp__loopctl__dispatch`'s " +
  "response or from the `implementer_dispatch_id` on a story.";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function refuse(body) {
  return { error: true, status: 0, body };
}

export function revokeDispatchPath(dispatchId) {
  return `/api/v1/dispatches/${encodeURIComponent(dispatchId)}/revoke`;
}

/**
 * A malformed id is refused HERE, before any call.
 *
 * Not for tidiness: a path id that is not a UUID reaches
 * `LoopctlWeb.CastErrorHandler`'s `Ecto.Query.CastError` clause and answers 404 — the
 * SAME 404 a well-formed id naming no dispatch gets. Two problems with opposite remedies
 * ("fix the argument" versus "that dispatch is gone") would otherwise have one
 * indistinguishable answer.
 *
 * The refusal names the SHAPE and never echoes the value: a malformed id is often a
 * token or a pasted line that landed in the wrong argument, and a tool result goes into
 * the transcript.
 */
export async function revokeDispatch({ dispatch_id } = {}, { apiCall } = {}) {
  if (typeof dispatch_id !== "string" || dispatch_id.trim() === "") {
    return refuse(MISSING_ID);
  }

  if (!UUID_RE.test(dispatch_id)) {
    return refuse(
      "`dispatch_id` must be a UUID (8-4-4-4 hex digits then 12, lowercase or upper). " +
        `Got a ${dispatch_id.length}-character string that is not one. The value is not ` +
        "repeated here: a malformed id is often something pasted into the wrong argument, " +
        "and a tool result lands in the transcript.",
    );
  }

  return apiCall("POST", revokeDispatchPath(dispatch_id), null);
}
