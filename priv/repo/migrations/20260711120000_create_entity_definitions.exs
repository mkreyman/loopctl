defmodule Loopctl.Repo.Migrations.CreateEntityDefinitions do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # Epic 30 / US-30.1: the per-tenant table backing `Loopctl.ContextRetriever`.
  # A tenant admin declares "entities" (name + typed fields + a loopctl-internal
  # backing source) that later stories turn into a governed agent query surface.
  # The SERVER column allowlist lives in code (`Loopctl.ContextRetriever.Entity`),
  # not this table — `fields` stores only the tenant's declared, allowlist-validated
  # field set. `enable_rls/1` applies ENABLE (not FORCE) row-level security so
  # tenant A's definitions are invisible to tenant B.
  def change do
    create table(:entity_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :backing_source, :string, null: false
      add :fields, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    # Entity name is unique per tenant.
    create unique_index(:entity_definitions, [:tenant_id, :name])

    enable_rls(:entity_definitions)
  end
end
