defmodule Loopctl.Repo.Migrations.DropChangeThreads do
  @moduledoc """
  #984: Epic 45's change threads are deleted (its successor is Epic 47, where landing belongs
  to chg). This drops what only that epic wrote:

  - the thread ledger, its reviews and its issue links (`thread_entries`, `thread_reviews`,
    `thread_issue_links`, `thread_checkpoints`), in FK order
  - the interactive claim routes (`claim_routes`)
  - the browser login (`browser_sessions`, `webauthn_login_challenges`)
  - `runner_dispatches.mode` and its CHECK, and `review` from `runner_dispatches_kind`
  - `thread` from `intake_sources_mode`: a source still on it is moved to `pr` first, the only
    route there is now
  - queued Oban jobs of the four deleted workers, which would otherwise fail on a missing
    module every time they ran

  Production held no rows in any of the dropped tables and no `review` dispatch when this was
  written (2026-10-18), and one `thread` intake source. The `kind` CHECK is restored inside
  the same transaction as the delete of review rows, so it can never refuse.

  `tenant_root_authenticators_credential_id_uidx` stays: a credential id is globally unique
  whether or not anything looks a tenant up by it.

  Irreversible: `down` raises rather than recreate empty tables nothing reads.
  """

  use Ecto.Migration

  @workers ~w(
    Loopctl.Workers.ThreadMergeWorker
    Loopctl.Workers.ThreadMergeSweepWorker
    Loopctl.Workers.ThreadIssueLinkWorker
    Loopctl.Workers.ReviewCeilingWorker
  )

  def up do
    execute("DROP TABLE IF EXISTS thread_entries")
    execute("DROP TABLE IF EXISTS thread_reviews")
    execute("DROP TABLE IF EXISTS thread_issue_links")
    execute("DROP TABLE IF EXISTS thread_checkpoints")
    execute("DROP TABLE IF EXISTS claim_routes")
    execute("DROP TABLE IF EXISTS browser_sessions")
    execute("DROP TABLE IF EXISTS webauthn_login_challenges")

    drop constraint(:runner_dispatches, :runner_dispatches_mode)

    alter table(:runner_dispatches) do
      remove :mode
    end

    execute("DELETE FROM runner_dispatches WHERE kind = 'review'")
    drop constraint(:runner_dispatches, :runner_dispatches_kind)

    create constraint(:runner_dispatches, :runner_dispatches_kind,
             check: "kind IN ('triage', 'implement')"
           )

    execute("UPDATE intake_sources SET mode = 'pr' WHERE mode = 'thread'")
    drop constraint(:intake_sources, :intake_sources_mode)
    create constraint(:intake_sources, :intake_sources_mode, check: "mode IN ('pr')")

    workers = Enum.map_join(@workers, ", ", &"'#{&1}'")
    execute("DELETE FROM oban_jobs WHERE worker IN (#{workers})")
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "#{__MODULE__} is irreversible: the change-thread tables and their code are deleted " <>
          "(#984), and nothing would read them if they were recreated."
  end
end
