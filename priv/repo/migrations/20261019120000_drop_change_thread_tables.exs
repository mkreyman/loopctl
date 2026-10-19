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

  TWO RELEASES, ENFORCED. A database that holds tenants and recorded the expand migration
  minutes ago is being upgraded from before #991 in ONE release_command, the case the split
  exists to prevent: the machines still on that release would read the dropped column and
  tables for the rest of the rolling deploy. It refuses, naming the remedy (deploy the release
  that carries the expand migration first). A database with no tenants — a fresh install, CI,
  a test run — has no previous release serving, so both run back to back.

  The DROPs take ACCESS EXCLUSIVE locks while the live release serves, so the transaction sets
  a 5s `lock_timeout`: a long-running transaction on `runner_dispatches` fails this release
  command (retry the deploy) instead of queueing every dispatch read and write behind it.

  `tenant_root_authenticators_credential_id_uidx` (added with the deleted login) stays. A
  WebAuthn registration always mints a NEW credential id, so the index refuses only a credential
  id seen before — a replayed attestation, never a legitimate enrolment — and it costs nothing.
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

  @expand_version 20_261_018_120_000

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    refuse_single_release_upgrade!()

    for table <- @tables, do: execute("DROP TABLE IF EXISTS #{table}")

    execute("ALTER TABLE runner_dispatches DROP CONSTRAINT IF EXISTS runner_dispatches_mode")
    execute("ALTER TABLE runner_dispatches DROP COLUMN IF EXISTS mode")

    workers = Enum.map_join(@workers, ", ", &"'#{&1}'")
    execute("DELETE FROM oban_jobs WHERE worker IN (#{workers})")
  end

  defp refuse_single_release_upgrade! do
    %{rows: [[recent?, tenants]]} =
      repo().query!(
        """
        SELECT
          EXISTS (
            SELECT 1 FROM schema_migrations
            WHERE version = $1
              AND inserted_at > (now() AT TIME ZONE 'utc') - interval '10 minutes'
          ),
          (SELECT count(*) FROM tenants)
        """,
        [@expand_version]
      )

    if recent? and tenants > 0 do
      raise Ecto.MigrationError,
        message:
          "#{__MODULE__} refuses to run in the same release as " <>
            "#{@expand_version}_retire_change_thread_modes: the release it replaces still " <>
            "reads the tables and column this drops. Deploy the release that carries " <>
            "#{@expand_version} first, let it reach every machine, then deploy this one."
    end
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "#{__MODULE__} is irreversible: nothing reads the change-thread tables or " <>
          "runner_dispatches.mode (#984)."
  end
end
