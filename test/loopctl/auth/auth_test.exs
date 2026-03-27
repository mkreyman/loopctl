defmodule Loopctl.AuthTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey

  describe "generate_api_key/1" do
    test "generates API key with raw key and persisted record" do
      tenant = fixture(:tenant)

      assert {:ok, {raw_key, %ApiKey{} = api_key}} =
               Auth.generate_api_key(%{
                 tenant_id: tenant.id,
                 name: "test-key",
                 role: :user
               })

      assert String.starts_with?(raw_key, "lc_")
      assert String.length(raw_key) >= 40
      assert api_key.key_prefix == String.slice(raw_key, 0, 8)
      assert String.length(api_key.key_hash) == 64
      assert api_key.role == :user
      assert api_key.tenant_id == tenant.id
      assert api_key.name == "test-key"
      # Raw key is NOT stored in any field
      refute api_key.key_hash == raw_key
    end

    test "superadmin key has nil tenant_id" do
      assert {:ok, {raw_key, %ApiKey{} = api_key}} =
               Auth.generate_api_key(%{
                 name: "superadmin-key",
                 role: :superadmin
               })

      assert String.starts_with?(raw_key, "lc_")
      assert api_key.tenant_id == nil
      assert api_key.role == :superadmin
    end

    test "non-superadmin key requires tenant_id" do
      assert {:error, changeset} =
               Auth.generate_api_key(%{
                 name: "no-tenant",
                 role: :user
               })

      assert errors_on(changeset).tenant_id != []
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = Auth.generate_api_key(%{})
      errors = errors_on(changeset)
      assert errors.name != []
      assert errors.role != []
    end
  end

  describe "verify_api_key/1" do
    test "verifies valid raw key" do
      tenant = fixture(:tenant)

      {:ok, {raw_key, original}} =
        Auth.generate_api_key(%{
          tenant_id: tenant.id,
          name: "verify-test",
          role: :user
        })

      assert {:ok, %ApiKey{} = verified} = Auth.verify_api_key(raw_key)
      assert verified.id == original.id
      assert verified.tenant_id == tenant.id
      assert verified.role == :user
      # Tenant should be preloaded
      assert verified.tenant.id == tenant.id
    end

    test "rejects revoked key" do
      {raw_key, api_key} = fixture(:api_key)
      {:ok, _revoked} = Auth.revoke_api_key(api_key)

      assert {:error, :unauthorized} = Auth.verify_api_key(raw_key)
    end

    test "rejects expired key" do
      tenant = fixture(:tenant)

      {:ok, {raw_key, _api_key}} =
        Auth.generate_api_key(%{
          tenant_id: tenant.id,
          name: "expired-key",
          role: :user,
          expires_at: ~U[2025-01-01 00:00:00Z]
        })

      assert {:error, :unauthorized} = Auth.verify_api_key(raw_key)
    end

    test "rejects unknown key" do
      assert {:error, :unauthorized} =
               Auth.verify_api_key("lc_totally_invalid_key_that_does_not_exist")
    end
  end

  describe "revoke_api_key/1" do
    test "sets revoked_at" do
      {_raw_key, api_key} = fixture(:api_key)
      assert is_nil(api_key.revoked_at)

      assert {:ok, revoked} = Auth.revoke_api_key(api_key)
      assert %DateTime{} = revoked.revoked_at
    end

    test "revoked key cannot be verified" do
      {raw_key, api_key} = fixture(:api_key)
      {:ok, _} = Auth.revoke_api_key(api_key)

      assert {:error, :unauthorized} = Auth.verify_api_key(raw_key)
    end
  end

  describe "list_api_keys/2" do
    test "lists keys for a tenant" do
      tenant = fixture(:tenant)

      {_raw1, _key1} =
        fixture(:api_key, %{tenant_id: tenant.id, name: "key-1", role: :user})

      {_raw2, _key2} =
        fixture(:api_key, %{tenant_id: tenant.id, name: "key-2", role: :agent})

      assert {:ok, keys} = Auth.list_api_keys(tenant.id)
      assert length(keys) == 2
      names = Enum.map(keys, & &1.name)
      assert "key-1" in names
      assert "key-2" in names
    end

    test "excludes revoked keys by default" do
      tenant = fixture(:tenant)
      {_raw, _active_key} = fixture(:api_key, %{tenant_id: tenant.id, name: "active"})
      {_raw2, revoked_key} = fixture(:api_key, %{tenant_id: tenant.id, name: "revoked"})
      Auth.revoke_api_key(revoked_key)

      assert {:ok, keys} = Auth.list_api_keys(tenant.id)
      assert length(keys) == 1
      assert hd(keys).name == "active"
    end

    test "includes revoked keys when requested" do
      tenant = fixture(:tenant)
      {_raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, name: "active"})
      {_raw2, key2} = fixture(:api_key, %{tenant_id: tenant.id, name: "revoked"})
      Auth.revoke_api_key(key2)

      assert {:ok, keys} = Auth.list_api_keys(tenant.id, include_revoked: true)
      assert length(keys) == 2
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot access tenant B's keys" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      {_raw, _key_a} = fixture(:api_key, %{tenant_id: tenant_a.id, name: "key-a"})
      {_raw, _key_b} = fixture(:api_key, %{tenant_id: tenant_b.id, name: "key-b"})

      assert {:ok, keys_a} = Auth.list_api_keys(tenant_a.id)
      assert length(keys_a) == 1
      assert hd(keys_a).name == "key-a"

      assert {:ok, keys_b} = Auth.list_api_keys(tenant_b.id)
      assert length(keys_b) == 1
      assert hd(keys_b).name == "key-b"
    end
  end

  describe "hash_key/1" do
    test "produces consistent SHA-256 hex digest" do
      raw = "lc_test_key_123"
      hash1 = Auth.hash_key(raw)
      hash2 = Auth.hash_key(raw)
      assert hash1 == hash2
      assert String.length(hash1) == 64
      assert Regex.match?(~r/^[a-f0-9]{64}$/, hash1)
    end
  end

  describe "generate_raw_key/0" do
    test "produces key with lc_ prefix" do
      key = Auth.generate_raw_key()
      assert String.starts_with?(key, "lc_")
      assert String.length(key) >= 40
    end

    test "produces unique keys" do
      key1 = Auth.generate_raw_key()
      key2 = Auth.generate_raw_key()
      refute key1 == key2
    end
  end
end
