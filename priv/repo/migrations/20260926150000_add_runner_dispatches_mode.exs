defmodule Loopctl.Repo.Migrations.AddRunnerDispatchesMode do
  @moduledoc """
  US-45.4 (Epic 45, change threads): the merge route an implement dispatch was PLACED under.

  `Loopctl.Runners.DispatchLedger.record_sent/3` copies the story's intake source `mode` onto
  the ledger row when the dispatch is first sent, and the merge gate reads it from the row of
  the story's current claim. A source's mode therefore only decides what FUTURE placements get,
  and a story already placed keeps the route it was built for however the source changes.

  NULLABLE, no default and no backfill: every row written before this column, and every
  non-implement row, is NULL, which the gate reads as `pr` — the only route there was. No
  manual step.
  """

  use Ecto.Migration

  def up do
    alter table(:runner_dispatches) do
      add :mode, :string, size: 16
    end

    create constraint(:runner_dispatches, :runner_dispatches_mode,
             check: "mode IS NULL OR mode IN ('pr', 'thread')"
           )
  end

  def down do
    drop constraint(:runner_dispatches, :runner_dispatches_mode)

    alter table(:runner_dispatches) do
      remove :mode
    end
  end
end
