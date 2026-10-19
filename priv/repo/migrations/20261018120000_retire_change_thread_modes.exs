defmodule Loopctl.Repo.Migrations.RetireChangeThreadModes do
  @moduledoc """
  #984, the EXPAND half: Epic 45's change threads are deleted (its successor is Epic 47, where
  landing belongs to chg), and this narrows what the new release no longer writes or reads
  while leaving everything the PREVIOUS release still touches in place.

  It runs as Fly's `release_command` before a ROLLING deploy, so the old release keeps serving
  on the other machines after it commits. That release's `DispatchRecord` still selects and
  inserts `runner_dispatches.mode`, and its thread crons still read the thread tables, so
  neither may go here. The tables, the column and its CHECK are dropped by the CONTRACT
  migration (US-47.9), which ships in a release after this one is live everywhere.

  - `intake_sources_mode` loses `thread`. A source still on it is moved to `pr` first, the only
    route there is now. That UPDATE writes no `intake_source_mode_set` audit entry, so an
    operator moves the source with `intake_source_update` BEFORE deploying (CHANGELOG); this is
    the backstop for a source nobody moved.
  - `runner_dispatches_kind` loses `review`. Nothing places a review dispatch any more, and the
    previous release only did so through a thread.
  - Queued Oban jobs of the four retired workers are deleted, since the new release has no
    module to run them. The old release's crons can enqueue more until it is replaced; the
    contract migration deletes those.

  Production held no thread, review, claim-route or browser-session rows when this was
  written (2026-10-18), no `review` dispatch, and one `thread` intake source.

  Irreversible: `down` raises rather than widen a CHECK nothing writes to.
  """

  use Ecto.Migration

  @workers ~w(
    Loopctl.Workers.ThreadMergeWorker
    Loopctl.Workers.ThreadMergeSweepWorker
    Loopctl.Workers.ThreadIssueLinkWorker
    Loopctl.Workers.ReviewCeilingWorker
  )

  def up do
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
        "#{__MODULE__} is irreversible: `thread` and `review` are no longer written by any " <>
          "release (#984)."
  end
end
