defmodule Loopctl.Repo.Migrations.CreateTokenBudgets do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:token_budgets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :scope_type, :string, null: false
      add :scope_id, :binary_id, null: false

      add :budget_millicents, :bigint, null: false
      add :budget_input_tokens, :bigint
      add :budget_output_tokens, :bigint
      add :alert_threshold_pct, :integer, null: false, default: 80
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # scope_type CHECK constraint
    execute(
      "ALTER TABLE token_budgets ADD CONSTRAINT token_budgets_scope_type_check CHECK (scope_type IN ('project', 'epic', 'story'))",
      "ALTER TABLE token_budgets DROP CONSTRAINT token_budgets_scope_type_check"
    )

    # Composite unique index — one budget per (tenant, scope_type, scope_id)
    create unique_index(:token_budgets, [:tenant_id, :scope_type, :scope_id])

    # Lookup indexes
    create index(:token_budgets, [:tenant_id])
    create index(:token_budgets, [:tenant_id, :scope_type])

    enable_rls(:token_budgets)

    # Add default_story_budget_millicents to tenants table
    alter table(:tenants) do
      add :default_story_budget_millicents, :bigint
    end
  end
end
