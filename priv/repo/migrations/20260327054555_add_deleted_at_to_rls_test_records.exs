defmodule Loopctl.Repo.Migrations.AddDeletedAtToRlsTestRecords do
  use Ecto.Migration

  def change do
    alter table(:rls_test_records) do
      add :deleted_at, :utc_datetime_usec
    end
  end
end
