defmodule Loopctl.Repo.AddTrustTierMigrationTest do
  @moduledoc """
  US-26.7.1 / AC-26.7.1.1 — proves the `trust_tier` backfill SQL (run inside
  the `AddTrustTierToTenants` migration) promotes exactly the tenants that
  have an enrolled root authenticator to `human_anchored`, leaving every
  other tenant at the restrictive default `agent_rooted`.

  Exercises the EXACT SQL string the migration runs (kept identical here so a
  future edit to one without the other fails this test), against tenants
  inserted directly via `Tenant.create_changeset/2` + `AdminRepo.insert!/1`
  (bypassing `signup_changeset/2`/`self_signup_changeset/2`, so the
  struct/schema-level `trust_tier` default of `:agent_rooted` is what
  actually lands in the row — mirroring the pre-migration/legacy-row shape).
  """
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Tenants.RootAuthenticator
  alias Loopctl.Tenants.Tenant

  @backfill_sql """
  UPDATE tenants
  SET trust_tier = 'human_anchored'
  WHERE id IN (SELECT DISTINCT tenant_id FROM tenant_root_authenticators)
  """

  setup do
    pid = Sandbox.start_owner!(AdminRepo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  test "promotes only tenants with an enrolled root authenticator to human_anchored" do
    with_auth = insert_tenant!("With Auth")
    without_auth = insert_tenant!("Without Auth")

    # Both land on the restrictive struct/schema default before the backfill —
    # this is the "nil/unknown is never permissive" invariant AC-26.7.1.1 requires.
    assert with_auth.trust_tier == :agent_rooted
    assert without_auth.trust_tier == :agent_rooted

    %RootAuthenticator{tenant_id: with_auth.id}
    |> RootAuthenticator.create_changeset(%{
      credential_id: :crypto.strong_rand_bytes(16),
      public_key: :erlang.term_to_binary(%{kty: "OKP"}),
      attestation_format: "none",
      sign_count: 0,
      friendly_name: "Primary"
    })
    |> AdminRepo.insert!()

    AdminRepo.query!(@backfill_sql)

    assert AdminRepo.get!(Tenant, with_auth.id).trust_tier == :human_anchored

    assert AdminRepo.get!(Tenant, without_auth.id).trust_tier == :agent_rooted,
           "a tenant with no enrolled authenticator must stay on the restrictive default"
  end

  # Review #8 — DB-layer enforcement of the trust_tier value set.
  test "tenants_trust_tier_check rejects a value outside the enum" do
    unique = System.unique_integer([:positive])

    assert_raise Postgrex.Error, ~r/tenants_trust_tier_check/, fn ->
      AdminRepo.query!(
        """
        INSERT INTO tenants (id, name, slug, email, status, settings, trust_tier, inserted_at, updated_at)
        VALUES (gen_random_uuid(), 'X', $1, $2, 'active', '{}', 'bogus_tier', now(), now())
        """,
        ["chk-#{unique}", "chk-#{unique}@example.com"]
      )
    end
  end

  # Review #7 — DB-layer backstop for RequireHumanAnchor's superadmin
  # (tenant_id IS NULL) exemption: tenant-null IFF superadmin.
  test "api_keys_superadmin_iff_null_tenant rejects a non-superadmin key with NULL tenant_id" do
    assert_raise Postgrex.Error, ~r/api_keys_superadmin_iff_null_tenant/, fn ->
      AdminRepo.query!(
        """
        INSERT INTO api_keys (id, tenant_id, name, key_hash, key_prefix, role, inserted_at, updated_at)
        VALUES (gen_random_uuid(), NULL, 'x', $1, 'lc_xxxxx', 'user', now(), now())
        """,
        [Base.encode16(:crypto.strong_rand_bytes(16))]
      )
    end
  end

  test "api_keys_superadmin_iff_null_tenant rejects a superadmin key WITH a tenant_id" do
    tenant = insert_tenant!("Has Tenant")

    assert_raise Postgrex.Error, ~r/api_keys_superadmin_iff_null_tenant/, fn ->
      AdminRepo.query!(
        """
        INSERT INTO api_keys (id, tenant_id, name, key_hash, key_prefix, role, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, 'x', $2, 'lc_xxxxx', 'superadmin', now(), now())
        """,
        [Ecto.UUID.dump!(tenant.id), Base.encode16(:crypto.strong_rand_bytes(16))]
      )
    end
  end

  defp insert_tenant!(name) do
    unique = System.unique_integer([:positive])

    %Tenant{}
    |> Tenant.create_changeset(%{
      name: name,
      slug: "trust-tier-migration-#{unique}",
      email: "trust-tier-migration-#{unique}@example.com"
    })
    |> AdminRepo.insert!()
  end
end
