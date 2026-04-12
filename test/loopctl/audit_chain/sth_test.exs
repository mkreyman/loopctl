defmodule Loopctl.AuditChain.SthTest do
  @moduledoc """
  Tests for US-26.1.2 — Signed Tree Heads.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Verifier

  setup :verify_on_exit!

  defp make_entry(overrides \\ %{}) do
    Map.merge(
      %{
        action: "test_event",
        actor_lineage: ["test"],
        entity_type: "test",
        payload: %{"k" => "v"}
      },
      overrides
    )
  end

  defp setup_tenant_with_entries(count) do
    tenant = fixture(:tenant, %{slug: "sth-test-#{System.unique_integer([:positive])}"})
    pub_key = :crypto.strong_rand_bytes(32)

    tenant =
      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: pub_key)
      |> Loopctl.AdminRepo.update!()

    # Set up mock to return a consistent private key
    {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    Mox.expect(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
    Loopctl.TenantKeys.init_cache()

    for _ <- 1..count do
      {:ok, _} = AuditChain.append(tenant.id, make_entry())
    end

    # Override the tenant's public key with the one matching the mock
    # private key so STH signature verification works
    {matching_pub, _} = :crypto.generate_key(:eddsa, :ed25519, priv)
    real_pub = matching_pub

    tenant =
      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: real_pub)
      |> Loopctl.AdminRepo.update!()

    {tenant, priv, real_pub}
  end

  describe "compute_merkle_root/1" do
    test "returns deterministic merkle root" do
      tenant = fixture(:tenant)

      for _ <- 1..5 do
        {:ok, _} = AuditChain.append(tenant.id, make_entry())
      end

      {:ok, root1} = AuditChain.compute_merkle_root(tenant.id)
      {:ok, root2} = AuditChain.compute_merkle_root(tenant.id)

      assert root1 == root2
      assert byte_size(root1) == 32
    end

    test "returns nil for empty chain" do
      tenant = fixture(:tenant)
      assert {:ok, nil} = AuditChain.compute_merkle_root(tenant.id)
    end
  end

  describe "sign_and_store_tree_head/1" do
    test "creates an STH with valid signature" do
      {tenant, _priv, pub_key} = setup_tenant_with_entries(3)

      assert {:ok, sth} = AuditChain.sign_and_store_tree_head(tenant.id)

      assert sth.chain_position == 2
      assert byte_size(sth.merkle_root) == 32
      assert byte_size(sth.signature) > 0
      assert sth.tenant_id == tenant.id

      # Verify signature
      assert {:ok, true} = Verifier.verify_sth(sth, pub_key)
    end

    test "is idempotent — no new STH when chain hasn't grown" do
      {tenant, _priv, _pub_key} = setup_tenant_with_entries(3)

      {:ok, sth1} = AuditChain.sign_and_store_tree_head(tenant.id)
      refute AuditChain.sth_needed?(tenant.id)

      # Second call would be a no-op in the worker since sth_needed? is false
      assert sth1.chain_position == 2
    end

    test "returns error for empty chain" do
      tenant = fixture(:tenant)
      assert {:error, :empty_chain} = AuditChain.sign_and_store_tree_head(tenant.id)
    end
  end

  describe "Verifier.verify_sth/2" do
    test "accepts valid STH, rejects tampered" do
      {tenant, _priv, pub_key} = setup_tenant_with_entries(3)
      {:ok, sth} = AuditChain.sign_and_store_tree_head(tenant.id)

      assert {:ok, true} = Verifier.verify_sth(sth, pub_key)

      # Tamper with merkle_root
      tampered = %{sth | merkle_root: :crypto.strong_rand_bytes(32)}
      assert {:error, :invalid_signature} = Verifier.verify_sth(tampered, pub_key)
    end

    test "rejects signature from wrong key" do
      {tenant, _priv, _pub_key} = setup_tenant_with_entries(3)
      {:ok, sth} = AuditChain.sign_and_store_tree_head(tenant.id)

      wrong_key = :crypto.strong_rand_bytes(32)
      assert {:error, :invalid_signature} = Verifier.verify_sth(sth, wrong_key)
    end
  end

  describe "get_latest_sth/1 and get_sth_at_position/2" do
    test "returns the latest STH" do
      {tenant, _priv, _pub_key} = setup_tenant_with_entries(3)
      {:ok, sth} = AuditChain.sign_and_store_tree_head(tenant.id)

      latest = AuditChain.get_latest_sth(tenant.id)
      assert latest.id == sth.id
    end

    test "get_sth_at_position returns the right STH" do
      {tenant, _priv, _pub_key} = setup_tenant_with_entries(3)
      {:ok, sth} = AuditChain.sign_and_store_tree_head(tenant.id)

      found = AuditChain.get_sth_at_position(tenant.id, 1)
      assert found.id == sth.id

      not_found = AuditChain.get_sth_at_position(tenant.id, 100)
      assert not_found == nil
    end
  end

  describe "sth_needed?/1" do
    test "returns true when chain has entries but no STH" do
      tenant = fixture(:tenant)
      {:ok, _} = AuditChain.append(tenant.id, make_entry())

      assert AuditChain.sth_needed?(tenant.id)
    end

    test "returns false for empty chain" do
      tenant = fixture(:tenant)
      refute AuditChain.sth_needed?(tenant.id)
    end
  end
end
