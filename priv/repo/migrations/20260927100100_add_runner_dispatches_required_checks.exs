defmodule Loopctl.Repo.Migrations.AddRunnerDispatchesRequiredChecks do
  @moduledoc """
  US-45.6: the CI checks an implement dispatch's thread must pass, BOUND AT PLACEMENT beside
  its merge mode and base branch (`20260926150000`). A source changed after placement — flipped
  back to `pr` with its list cleared, or given a different list — decides only what later
  placements get, so a story already placed as a thread is never refused for a policy nobody
  applied to it.

  NULLABLE, no backfill: a row written before the column, or a non-implement row, records
  none, and the merge gate then reads the source's current list, the only policy there was.
  No manual step.
  """

  use Ecto.Migration

  def change do
    alter table(:runner_dispatches) do
      add :required_checks, {:array, :string}
    end
  end
end
