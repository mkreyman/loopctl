defmodule Loopctl.Repo.Migrations.AddTenantColumns do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :email, :string
      add :settings, :map, default: %{}, null: false
    end

    create index(:tenants, [:status])
  end
end
