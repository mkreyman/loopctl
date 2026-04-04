defmodule Loopctl.Repo.Migrations.AddTokenUsageReportsSkillVersionIdIndex do
  use Ecto.Migration

  def change do
    create index(:token_usage_reports, [:skill_version_id], where: "skill_version_id IS NOT NULL")
  end
end
