defmodule Loopctl.Repo.Migrations.AddCustodyHaltedAtToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :custody_halted_at, :utc_datetime_usec
    end
  end
end
