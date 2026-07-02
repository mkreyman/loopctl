defmodule Loopctl.Repo.Migrations.AddReportedDoneRequiresAgentCheckToStories do
  @moduledoc """
  Chain-of-custody INVARIANT 1 (L2 structural, docs/chain-of-custody-v2.md
  §2.1/§2.2). The threat: the self-verify guard (`validate_not_self_verify/2`)
  passes VACUOUSLY when a `reported_done` story has a NULL `assigned_agent_id` —
  a non-nil verifier is never `== NULL`, so "nobody verifies their own work" is
  satisfied for a report with no implementer. An agent could implement work, erase
  its own `assigned_agent_id`, and then self-verify.

  SCOPED CONSTRAINT — dispatch-identity erasure. This forbids the precise
  illegitimate shape: a story that carries an implementer DISPATCH lineage
  (`implementer_dispatch_id IS NOT NULL` — the "was dispatched to an implementer"
  marker that `force_unclaim_story` deliberately does NOT clear) but has lost its
  `assigned_agent_id` while still `reported_done`. No legitimate code path produces
  this: `claim_story` sets `assigned_agent_id` (and `implementer_dispatch_id` for
  dispatched work) together, and nothing clears the agent while the story stays
  `reported_done`.

  Why NOT the broader "reported_done ⇒ assigned_agent_id NOT NULL": there are
  legitimate never-dispatched producers of `reported_done` + NULL agent that carry
  NO dispatch lineage —
    * `backfill_story/4` (reported_done + verified, stamps `metadata.backfill`)
    * bulk mark-complete (`BulkOperations.apply_mark_complete/1` — reported_done +
      verified)
    * import with `initial_agent_status = reported_done` / `initial_verified_status
      = verified`
  A broad CHECK would break all of these. The AGENTLESS-but-never-dispatched case
  is instead closed at the OPERATION level: `Loopctl.Progress.custody_orphaned?/1`
  makes `validate_not_self_verify/2` and `validate_not_self_review/2` FAIL CLOSED
  (`:missing_assigned_agent`) on any `reported_done` + unverified + NULL-agent +
  NULL-dispatch story, so it can never be vacuously verified or reviewed. The two
  layers together close the fail-open (structural DB backstop for the dispatch
  case; fail-closed guard for the import/backfill-shaped case).

  Pre-flight: dev (`loopctl_dev`) and test (`loopctl_test`) both have 0 stories, so
  the constraint applies cleanly; no legacy backfill needed.

  Production-safe locking: added `NOT VALID` first (a fast catalog-only change that
  does NOT scan the table), then `VALIDATE CONSTRAINT` in a separate statement —
  which takes only a `SHARE UPDATE EXCLUSIVE` lock (concurrent reads AND writes
  allowed) instead of the `ACCESS EXCLUSIVE` full-table lock a plain
  `ADD CONSTRAINT ... CHECK` would hold for the whole scan. Behavior is identical
  on the empty dev/test tables; this is purely the safe form for a populated
  production `stories` table.

  Reversible: the `execute/2` up/down pairs drop the constraint on rollback
  (the VALIDATE step's down is a no-op — dropping the constraint removes it whole).
  """
  use Ecto.Migration

  @check "agent_status <> 'reported_done' OR implementer_dispatch_id IS NULL OR assigned_agent_id IS NOT NULL"

  def change do
    execute(
      "ALTER TABLE stories ADD CONSTRAINT stories_reported_done_requires_agent CHECK (#{@check}) NOT VALID",
      "ALTER TABLE stories DROP CONSTRAINT stories_reported_done_requires_agent"
    )

    execute(
      "ALTER TABLE stories VALIDATE CONSTRAINT stories_reported_done_requires_agent",
      # Down no-op: the ADD's down (above) drops the constraint entirely on rollback.
      "SELECT 1"
    )
  end
end
