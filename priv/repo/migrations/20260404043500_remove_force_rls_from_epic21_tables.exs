defmodule Loopctl.Repo.Migrations.RemoveForceRlsFromEpic21Tables do
  use Ecto.Migration

  @epic21_tables ~w(token_usage_reports token_budgets cost_summaries cost_anomalies)

  def up do
    for table <- @epic21_tables do
      execute("ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY")
    end
  end

  def down do
    for table <- @epic21_tables do
      execute("ALTER TABLE #{table} FORCE ROW LEVEL SECURITY")
    end
  end
end
