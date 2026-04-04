defmodule Loopctl.Repo.Migrations.AddUniqueIndexToCostAnomalies do
  use Ecto.Migration

  def change do
    create_if_not_exists(
      index(:cost_anomalies, [:tenant_id, :story_id, :anomaly_type],
        unique: true,
        where: "resolved = false",
        name: :cost_anomalies_unresolved_unique
      )
    )
  end
end
