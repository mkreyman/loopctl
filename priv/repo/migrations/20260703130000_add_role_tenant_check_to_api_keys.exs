defmodule Loopctl.Repo.Migrations.AddRoleTenantCheckToApiKeys do
  @moduledoc """
  US-26.7.1 (#7) — L2 database invariant backstopping `RequireHumanAnchor`'s
  superadmin exemption.

  The tier gate treats a key with `current_tenant: nil` (i.e. `tenant_id IS
  NULL`) as an exempt superadmin. This CHECK makes that biconditional
  STRUCTURAL: a key is tenant-null IF AND ONLY IF it is superadmin. So a
  non-superadmin key can never be tenant-null (which would spoof the
  exemption), and a superadmin key can never carry a tenant_id. Mirrors the
  application-level `ApiKey.validate_tenant_for_role/1`; existing rows already
  satisfy it.

  Auto-reversible via `create constraint` in `change`.
  """

  use Ecto.Migration

  def change do
    create constraint(:api_keys, :api_keys_superadmin_iff_null_tenant,
             check: "(role = 'superadmin') = (tenant_id IS NULL)"
           )
  end
end
