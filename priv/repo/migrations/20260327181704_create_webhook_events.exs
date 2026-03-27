defmodule Loopctl.Repo.Migrations.CreateWebhookEvents do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:webhook_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :webhook_id, references(:webhooks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_attempt_at, :utc_datetime_usec
      add :delivered_at, :utc_datetime_usec
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:webhook_events, [:tenant_id])
    create index(:webhook_events, [:webhook_id])
    create index(:webhook_events, [:status])
    create index(:webhook_events, [:webhook_id, :inserted_at])

    enable_rls(:webhook_events)
  end
end
