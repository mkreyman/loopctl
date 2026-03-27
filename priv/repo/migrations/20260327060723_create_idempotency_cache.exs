defmodule Loopctl.Repo.Migrations.CreateIdempotencyCache do
  use Ecto.Migration

  def change do
    create table(:idempotency_cache, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :idempotency_key, :string, null: false
      add :response_data, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:idempotency_cache, [:idempotency_key])
    create index(:idempotency_cache, [:expires_at])
  end
end
