defmodule Loopctl.Repo.Migrations.AddReportedDoneRequiresAgentCheckToStories do
  use Ecto.Migration

  # Run each ALTER in its OWN auto-committed transaction. This is REQUIRED for the
  # NOT VALID / VALIDATE split to actually help: inside a single Ecto-wrapped
  # transaction Postgres would hold the ADD-CONSTRAINT lock until COMMIT, i.e.
  # through the whole VALIDATE scan — an ACCESS-EXCLUSIVE-equivalent write block on
  # `stories` (the hottest table). With the DDL transaction disabled, ADD
  # CONSTRAINT ... NOT VALID commits first (fast, catalog-only, no scan), THEN
  # VALIDATE CONSTRAINT runs on its own taking only SHARE UPDATE EXCLUSIVE
  # (concurrent reads AND writes allowed). Same repo pattern as the CONCURRENTLY
  # index migrations (e.g. 20260625120000_add_articles_source_keyset_index).
  @disable_ddl_transaction true
  @disable_migration_lock true

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

  Online-safe locking: `@disable_ddl_transaction true` (see the module attribute
  note) makes `ADD CONSTRAINT ... NOT VALID` and `VALIDATE CONSTRAINT` each run in
  their own auto-committed transaction, so VALIDATE holds only a SHARE UPDATE
  EXCLUSIVE lock — concurrent reads and writes to `stories` continue during the
  scan. Behavior is identical on the empty dev/test tables; this is the
  production-safe form.

  Reversible: `down` drops the constraint (idempotent `IF EXISTS`).
  """

  @check "agent_status <> 'reported_done' OR implementer_dispatch_id IS NULL OR assigned_agent_id IS NOT NULL"

  def up do
    execute(
      "ALTER TABLE stories ADD CONSTRAINT stories_reported_done_requires_agent CHECK (#{@check}) NOT VALID"
    )

    execute("ALTER TABLE stories VALIDATE CONSTRAINT stories_reported_done_requires_agent")
  end

  def down do
    execute("ALTER TABLE stories DROP CONSTRAINT IF EXISTS stories_reported_done_requires_agent")
  end
end
