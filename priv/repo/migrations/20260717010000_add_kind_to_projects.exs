defmodule Loopctl.Repo.Migrations.AddKindToProjects do
  use Ecto.Migration

  # `kind` distinguishes a work-breakdown project (:work — the default, which carries the
  # chain-of-custody surface: epics, stories, dispatch, ui-tests) from a knowledge-only
  # scope (:kb — creatable by agent-rooted tenants, structurally barred from hosting any
  # work-breakdown item). Stored as a string like `status`. Every existing row is a work
  # project, so the NOT NULL default backfills them correctly.
  def change do
    alter table(:projects) do
      add :kind, :string, null: false, default: "work"
    end

    create index(:projects, [:tenant_id, :kind])
  end
end
