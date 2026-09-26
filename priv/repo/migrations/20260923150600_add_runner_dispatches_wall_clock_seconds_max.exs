defmodule Loopctl.Repo.Migrations.AddRunnerDispatchesWallClockSecondsMax do
  use Ecto.Migration

  @moduledoc """
  `runner_dispatches.wall_clock_seconds_max` — the longest `wall_clock_seconds` any winning
  push of the dispatch carried (`Loopctl.Runners.DispatchLedger`, #879, US-44.5). The runner's
  acceptance moves the claim's cap forward on it rather than on the latest push's clock, which
  a resume may have shortened while an earlier session still runs, and
  `Loopctl.Runners.Capacity` bounds an accepted session by it.

  NULL until the first push; a nullable column with no default, so adding it rewrites nothing.
  `add_if_not_exists` because an earlier draft of this change added the column inside
  `20260923150500`, and a database that ran that draft already has it.
  """

  def up do
    alter table(:runner_dispatches) do
      add_if_not_exists :wall_clock_seconds_max, :integer
    end
  end

  def down do
    alter table(:runner_dispatches) do
      remove_if_exists :wall_clock_seconds_max, :integer
    end
  end
end
