defmodule Loopctl.Repo.Migrations.AddTrustTierToTenants do
  @moduledoc """
  US-26.7.1 — capability-tiered trust: adds `trust_tier` to `tenants`.

  The RESTRICTIVE default (`agent_rooted`) honors "nil/unknown is never
  permissive" — an unrecognized/legacy row is treated as the LOWER-trust
  tier, never the higher one. The backfill below promotes every tenant
  that has an enrolled root authenticator (the WebAuthn human-anchor
  ceremony) to `human_anchored`, since only those tenants ever completed
  it. `tenants` carries no RLS policy (verified against
  `20260327051838_create_rls_infrastructure.exs` and
  `20260412180651_add_custody_halted_at_to_tenants.exs`), so there is no
  AdminRepo/Repo distinction to make inside a migration — plain SQL runs
  as the migration role.
  """

  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :trust_tier, :string, null: false, default: "agent_rooted"
    end

    execute(
      """
      UPDATE tenants
      SET trust_tier = 'human_anchored'
      WHERE id IN (SELECT DISTINCT tenant_id FROM tenant_root_authenticators)
      """,
      "SELECT 1"
    )

    # US-26.7.1 (#8) — enforce the Ecto.Enum's value set at the DB layer too
    # (L2 database invariant), so a raw/out-of-band write can never smuggle in
    # a third tier value. Auto-reversible via `create constraint` in `change`.
    create constraint(:tenants, :tenants_trust_tier_check,
             check: "trust_tier IN ('human_anchored', 'agent_rooted')"
           )
  end
end
