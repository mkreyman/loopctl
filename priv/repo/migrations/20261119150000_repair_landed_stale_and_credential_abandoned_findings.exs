defmodule Loopctl.Repo.Migrations.RepairLandedStaleAndCredentialAbandonedFindings do
  @moduledoc """
  Repairs the rows two defects left behind (both fixed in the same change):

  1. `Loopctl.Changes.Reconcile.stale_candidates/2` judged a change by its story's stage alone,
     and `merged` is not terminal, so every LANDED chg change was flagged `stale` six hours after
     it landed. A flag clears only on the change's next event, and a landed change sends none,
     so the flag would stand for good and, a day later, file a `stuck_change` finding. This
     clears `stale` on every cursor whose change has an applied, routed `landed` event that no
     applied `reverted` or `submitted` follows.

  2. `Loopctl.Changes.FindingFiler` abandoned an `open` action after six hourly waits for a
     missing forge credential, leaving its finding `:filed` with no issue. This returns such
     actions to `:pending` (due now, attempts reset), so the drainer files them now that the
     credential exists, or waits for it without a bound.

  Both are data-only and idempotent. `down` does nothing: re-flagging a landed change or
  re-abandoning an action would only restore the defect.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE change_cursors c
       SET attention = NULL, attention_at = NULL, updated_at = now()
     WHERE c.attention = 'stale'
       AND EXISTS (
             SELECT 1 FROM change_events e
              WHERE e.tenant_id = c.tenant_id AND e.repo = c.repo
                AND e.change_id = c.change_id AND e.kind = 'landed'
                AND e.applied_at IS NOT NULL AND e.routed
                AND NOT EXISTS (
                      SELECT 1 FROM change_events r
                       WHERE r.tenant_id = e.tenant_id AND r.repo = e.repo
                         AND r.change_id = e.change_id
                         AND r.kind IN ('reverted', 'submitted')
                         AND r.applied_at IS NOT NULL AND r.event_seq > e.event_seq
                    )
           )
    """)

    execute("""
    UPDATE chg_finding_actions a
       SET status = 'pending', abandoned_reason = NULL, attempts = 0,
           next_attempt_at = NULL, updated_at = now()
      FROM chg_findings f
     WHERE f.id = a.finding_id AND f.tenant_id = a.tenant_id
       AND a.action = 'open' AND a.status = 'abandoned'
       AND a.abandoned_reason = 'retries_exhausted'
       AND a.issue_number IS NULL
       AND a.last_error LIKE '%credential_unavailable%'
       AND f.state = 'filed' AND f.issue_number IS NULL
    """)
  end

  def down, do: :ok
end
