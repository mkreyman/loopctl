defmodule Loopctl.Repo.Migrations.DropChangeThreadTables do
  @moduledoc """
  US-47.9, the CONTRACT half of #984: drops what Epic 45 left behind once no release reads it.
  `20261018120000_retire_change_thread_modes` left these in place because the release it
  replaced still selected `runner_dispatches.mode` and ran crons over the thread tables during
  the rolling deploy; this ships in a later release, after that one was gone from every
  machine.

  - the thread ledger, its reviews and issue links, in FK order, then `claim_routes`,
    `browser_sessions` and `webauthn_login_challenges`
  - `runner_dispatches.mode` and its CHECK
  - queued Oban jobs of the four retired workers, again: the previous release's crons could
    enqueue them until it was replaced

  `IF EXISTS` throughout, so a database that already lacks them migrates cleanly. Production
  held no rows in any of the tables (2026-10-18). Irreversible: `down` raises.
  """

  use Ecto.Migration

  @workers ~w(
    Loopctl.Workers.ThreadMergeWorker
    Loopctl.Workers.ThreadMergeSweepWorker
    Loopctl.Workers.ThreadIssueLinkWorker
    Loopctl.Workers.ReviewCeilingWorker
  )

  @tables ~w(
    thread_entries
    thread_reviews
    thread_issue_links
    thread_checkpoints
    claim_routes
    browser_sessions
    webauthn_login_challenges
  )

  def up do
    for table <- @tables, do: execute("DROP TABLE IF EXISTS #{table}")

    execute("ALTER TABLE runner_dispatches DROP CONSTRAINT IF EXISTS runner_dispatches_mode")
    execute("ALTER TABLE runner_dispatches DROP COLUMN IF EXISTS mode")

    workers = Enum.map_join(@workers, ", ", &"'#{&1}'")
    execute("DELETE FROM oban_jobs WHERE worker IN (#{workers})")
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "#{__MODULE__} is irreversible: nothing reads the change-thread tables or " <>
          "runner_dispatches.mode (#984)."
  end
end
