defmodule Loopctl.Repo.Migrations.RequeueCredentialAbandonedForgeRows do
  @moduledoc """
  #1058: `Loopctl.Changes.RevertIssueOpener` and `Loopctl.Delivery.IssueCloser` waited for a
  missing forge credential inside the six-attempt transient bound, then abandoned the row
  `retries_exhausted`. Both now wait without a bound (`Loopctl.ForgeOutbox.mark_configuration_wait/5`).

  This returns the rows that bound abandoned while the credential was missing to `:pending`
  (due now, attempts reset), so the drainer performs them once the credential exists, or
  waits for it. A row is chosen only when its LAST error was the missing credential: one that
  failed at the forge for any other reason keeps its abandonment.

  Data-only and idempotent. `down` does nothing: re-abandoning would only restore the defect.
  """

  use Ecto.Migration

  def up do
    for table <- ["change_revert_issues", "intake_issue_closures"] do
      execute("""
      UPDATE #{table}
         SET status = 'pending', abandoned_reason = NULL, attempts = 0,
             next_attempt_at = NULL, updated_at = now()
       WHERE status = 'abandoned'
         AND abandoned_reason = 'retries_exhausted'
         AND last_error LIKE '%credential_unavailable%'
      """)
    end
  end

  def down, do: :ok
end
