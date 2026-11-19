defmodule Loopctl.Repo.Migrations.RequeueCredentialAbandonedForgeRows do
  @moduledoc """
  #1058: `Loopctl.Changes.RevertIssueOpener` and `Loopctl.Delivery.IssueCloser` waited for a
  missing forge credential inside the six-attempt transient bound, then abandoned the row
  `retries_exhausted`. Both now wait without a bound (`Loopctl.ForgeOutbox.mark_configuration_wait/5`).

  This returns the rows that bound abandoned while the credential was missing to `:pending`,
  due now, so the drainer performs them once the credential exists, or waits for it. A row is
  chosen only when its LAST error was the missing credential (one that failed at the forge for
  any other reason keeps its abandonment) and only when it was abandoned in the last
  14 days. That window is the rule `Loopctl.Intake.IssueClosures.requeue_abandoned/1`
  enforces: an old closure still names a live issue, and waking it labels, comments on and
  closes a ticket its reporter has moved on from. An older row is an operator's call
  (`requeue_abandoned(abandoned_after: ...)` for a closure).

  A revert row restarts at ONE attempt, not zero. `RevertIssueOpener` skips the marker search
  only on the first attempt, and a row the bound abandoned has made at least one, which may
  have opened the issue before its answer was lost; at one, the next claim searches first and
  never opens a second issue. A closure reads its issue on every attempt, so it restarts at zero.

  Data-only and idempotent. `down` does nothing: re-abandoning would only restore the defect.
  """

  use Ecto.Migration

  @window_days 14

  def up do
    for {table, attempts} <- [{"change_revert_issues", 1}, {"intake_issue_closures", 0}] do
      execute("""
      UPDATE #{table}
         SET status = 'pending', abandoned_reason = NULL, attempts = #{attempts},
             next_attempt_at = NULL, updated_at = now()
       WHERE status = 'abandoned'
         AND abandoned_reason = 'retries_exhausted'
         AND last_error LIKE '%credential_unavailable%'
         AND updated_at >= now() - interval '#{@window_days} days'
      """)
    end
  end

  def down, do: :ok
end
