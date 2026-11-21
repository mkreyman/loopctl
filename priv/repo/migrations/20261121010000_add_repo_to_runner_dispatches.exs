defmodule Loopctl.Repo.Migrations.AddRepoToRunnerDispatches do
  @moduledoc """
  Issue #1020: the repository each dispatch was sent for, so a runner's CONFIGURATION refusal
  (`branch_not_allowed`, `repo_not_allowed`, a budget over its limit) can be remembered per
  runner, kind and repository (`Loopctl.Runners.DispatchLedger.config_refusals/2`).

  Nullable and with no default, so the ALTER is a catalogue change and rewrites nothing. Rows
  written before it stay NULL; a NULL repo matches no repository, so no old refusal is read as
  a statement about a repository it never named. No backfill and no manual step.
  """

  use Ecto.Migration

  def change do
    alter table(:runner_dispatches) do
      add :repo, :text
    end
  end
end
