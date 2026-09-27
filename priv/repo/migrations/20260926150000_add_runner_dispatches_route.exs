defmodule Loopctl.Repo.Migrations.AddRunnerDispatchesRoute do
  @moduledoc """
  US-45.4 (Epic 45, change threads): the merge route an implement dispatch was PLACED under —
  its intake source's `mode`, and the `base_branch` it was sent with.

  `Loopctl.Runners.DispatchLedger.record_sent/4` writes both onto the ledger row when the
  dispatch is first sent, and the merge gate reads them from the row of the story's current
  claim. A source's mode and base branch therefore only decide what FUTURE placements get, and
  a story already placed keeps the route it was built for however the source changes.

  NULLABLE, no default and no backfill: every row written before these columns, and every
  non-implement row, is NULL. The gate reads a NULL mode as `pr` — the only route there was —
  and a NULL base branch as the source's current one. No manual step.

  `base_branch` is `text`, not a bounded string: it is copied from the dispatch as sent, and a
  length this table refused would fail a placement the wire already accepted.
  """

  use Ecto.Migration

  def up do
    alter table(:runner_dispatches) do
      add :mode, :string, size: 16
      add :base_branch, :text
    end

    create constraint(:runner_dispatches, :runner_dispatches_mode,
             check: "mode IS NULL OR mode IN ('pr', 'thread')"
           )
  end

  def down do
    drop constraint(:runner_dispatches, :runner_dispatches_mode)

    alter table(:runner_dispatches) do
      remove :mode
      remove :base_branch
    end
  end
end
