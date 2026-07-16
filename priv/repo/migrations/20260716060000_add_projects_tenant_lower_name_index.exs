defmodule Loopctl.Repo.Migrations.AddProjectsTenantLowerNameIndex do
  use Ecto.Migration

  @moduledoc """
  Functional index on `(tenant_id, lower(name))` so the case-insensitive
  name resolution in `Projects.resolve_by_name/2` (`lower(name) = lower($1)`
  scoped to a tenant) uses an index instead of a sequential scan. Without it
  the `lower(name)` comparison is non-sargable and each resolve seq-scans the
  tenant's projects; the resolve endpoint is the cheap per-repo call the harness
  makes frequently, so keep it O(log n) rather than O(tenant projects).
  """

  def change do
    create_if_not_exists index(:projects, [:tenant_id, "lower(name)"],
                           name: :projects_tenant_id_lower_name_index
                         )
  end
end
