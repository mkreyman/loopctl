defmodule Loopctl.Repo.Migrations.CreateVerificationResults do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:verification_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false

      add :orchestrator_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)

      add :result, :string, null: false
      add :summary, :text
      add :findings, :map, default: %{}
      add :review_type, :string
      add :iteration, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create index(:verification_results, [:tenant_id])
    create index(:verification_results, [:story_id])
    create index(:verification_results, [:orchestrator_agent_id])

    enable_rls(:verification_results)
  end
end
