defmodule Loopctl.Repo.Migrations.AddReportedByAgentIdToStories do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :reported_by_agent_id,
          references(:agents, type: :binary_id, on_delete: :nilify_all),
          null: true
    end

    create index(:stories, [:reported_by_agent_id])
  end
end
