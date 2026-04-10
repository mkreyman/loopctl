defmodule Loopctl.Repo.Migrations.AddMissionToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :mission, :text
    end
  end
end
