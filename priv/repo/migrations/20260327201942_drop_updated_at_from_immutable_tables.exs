defmodule Loopctl.Repo.Migrations.DropUpdatedAtFromImmutableTables do
  use Ecto.Migration

  def change do
    # Skill versions and skill results are immutable records --
    # they should not have updated_at columns.
    alter table(:skill_versions) do
      remove :updated_at, :utc_datetime_usec
    end

    alter table(:skill_results) do
      remove :updated_at, :utc_datetime_usec
    end
  end
end
