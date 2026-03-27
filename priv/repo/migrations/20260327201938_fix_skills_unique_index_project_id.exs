defmodule Loopctl.Repo.Migrations.FixSkillsUniqueIndexProjectId do
  use Ecto.Migration

  def change do
    # Drop old index that only covers (tenant_id, name) -- it doesn't
    # account for project_id, so two projects under the same tenant can't
    # have identically-named skills.
    drop_if_exists unique_index(:skills, [:tenant_id, :name], name: :skills_tenant_id_name_index)

    # Create a new unique index using COALESCE so NULL project_id is treated
    # as a sentinel value, making the index work correctly for both
    # tenant-wide (project_id IS NULL) and project-scoped skills.
    execute(
      """
      CREATE UNIQUE INDEX skills_tenant_project_name_index
      ON skills (tenant_id, COALESCE(project_id, '00000000-0000-0000-0000-000000000000'), name)
      """,
      """
      DROP INDEX IF EXISTS skills_tenant_project_name_index
      """
    )
  end
end
