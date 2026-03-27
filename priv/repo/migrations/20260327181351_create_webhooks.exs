defmodule Loopctl.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:webhooks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :url, :string, null: false
      add :signing_secret_encrypted, :binary, null: false
      add :events, {:array, :string}, null: false, default: []

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: true

      add :active, :boolean, null: false, default: true
      add :consecutive_failures, :integer, null: false, default: 0
      add :last_delivery_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:webhooks, [:tenant_id])
    create index(:webhooks, [:tenant_id, :active])
    create index(:webhooks, [:project_id])

    enable_rls(:webhooks)
  end
end
