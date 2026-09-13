defmodule Loopctl.Repo.Migrations.AddPushedAtToRunnerDispatches do
  use Ecto.Migration

  # Issue #815: `sent` meant both "pushed to the runner's socket" and "handed to a channel
  # that dropped it" (a second live socket, a custody halt landing before the push). The
  # channel stamps `pushed_at` when it actually pushes, so a row still `sent` with no
  # `pushed_at` is a dispatch that never left loopctl.
  #
  # A nullable column with no default: catalog-only, rewrites no rows, takes no long lock.
  def change do
    alter table(:runner_dispatches) do
      add :pushed_at, :utc_datetime_usec, null: true
    end
  end
end
