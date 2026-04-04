defmodule Loopctl.Repo.Migrations.AddDedupFlagsToTokenBudgets do
  use Ecto.Migration

  def change do
    alter table(:token_budgets) do
      add :warning_fired, :boolean, null: false, default: false
      add :exceeded_fired, :boolean, null: false, default: false
    end
  end
end
