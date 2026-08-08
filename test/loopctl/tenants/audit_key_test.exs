defmodule Loopctl.Tenants.AuditKeyTest do
  @moduledoc """
  Tests for US-26.0.2 — audit signing keypair generation, storage, and rotation.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Secrets
  alias Loopctl.TenantKeys
  alias Loopctl.Tenants

  setup :verify_on_exit!

  describe "signup generates audit keypair" do
    test "signup stores public key on tenant and writes private key to secrets adapter" do
      # Track what the mock secrets adapter receives
      test_pid = self()

      Mox.expect(Loopctl.MockSecrets, :set, fn name, value ->
        send(test_pid, {:secret_set, name, value})
        :ok
      end)

      attrs = %{
        "name" => "Audit Key Tenant",
        "slug" => "audit-key-test",
        "email" => "audit@test.com",
        "authenticators" => [
          %{
            attestation_result: %{
              credential_id: :crypto.strong_rand_bytes(32),
              public_key: :crypto.strong_rand_bytes(32),
              attestation_format: "none",
              sign_count: 0
            },
            friendly_name: "YubiKey"
          }
        ]
      }

      assert {:ok, %{tenant: tenant}} = Tenants.signup(attrs)

      # AC-26.0.2.1 + AC-26.0.2.2: public key stored on tenant
      assert is_binary(tenant.audit_signing_public_key)
      assert byte_size(tenant.audit_signing_public_key) == 32

      # AC-26.0.2.3: private key written to secrets
      assert_received {:secret_set, secret_name, private_key}
      assert secret_name == "TENANT_AUDIT_KEY_AUDIT_KEY_TEST"
      assert is_binary(private_key)
      assert byte_size(private_key) == 32

      # Verify the keypair is valid: sign and verify
      signature = :crypto.sign(:eddsa, :sha512, "test message", [private_key, :ed25519])

      assert :crypto.verify(
               :eddsa,
               :sha512,
               "test message",
               signature,
               [tenant.audit_signing_public_key, :ed25519]
             )
    end

    test "signup rolls back if secret write fails" do
      Mox.expect(Loopctl.MockSecrets, :set, fn _name, _value ->
        {:error, :network_failure}
      end)

      attrs = %{
        "name" => "Failing Tenant",
        "slug" => "fail-secret",
        "email" => "fail@test.com",
        "authenticators" => [
          %{
            attestation_result: %{
              credential_id: :crypto.strong_rand_bytes(32),
              public_key: :crypto.strong_rand_bytes(32),
              attestation_format: "none",
              sign_count: 0
            },
            friendly_name: "Test Key"
          }
        ]
      }

      assert {:error, {:audit_key_storage_failed, :network_failure}} = Tenants.signup(attrs)

      # AC-26.0.2.4: no tenant created
      assert {:error, :not_found} = Tenants.get_tenant_by_slug("fail-secret")
    end

    test "genesis audit entry includes public key" do
      Mox.expect(Loopctl.MockSecrets, :set, fn _name, _value -> :ok end)

      attrs = %{
        "name" => "Genesis Tenant",
        "slug" => "genesis-test",
        "email" => "genesis@test.com",
        "authenticators" => [
          %{
            attestation_result: %{
              credential_id: :crypto.strong_rand_bytes(32),
              public_key: :crypto.strong_rand_bytes(32),
              attestation_format: "none",
              sign_count: 0
            },
            friendly_name: "Test Key"
          }
        ]
      }

      assert {:ok, %{tenant: tenant}} = Tenants.signup(attrs)

      # AC-26.0.2.6: genesis audit entry
      import Ecto.Query
      alias Loopctl.Audit.AuditLog

      [entry] =
        from(a in AuditLog,
          where: a.tenant_id == ^tenant.id and a.action == "tenant_created",
          order_by: [desc: a.inserted_at],
          limit: 1
        )
        |> Loopctl.AdminRepo.all()

      assert entry.entity_type == "tenant"
      assert entry.actor_label == "human:webauthn"
      assert is_binary(entry.new_state["audit_signing_public_key"])
    end
  end

  describe "TenantKeys.get_private_key/1" do
    test "returns the key from secrets adapter and caches it" do
      tenant = fixture(:tenant)
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      Mox.expect(Loopctl.MockSecrets, :get, fn name ->
        :counters.add(call_count, 1, 1)
        send(test_pid, {:secret_get, name})
        {:ok, "fake-private-key-32bytes-padded!"}
      end)

      TenantKeys.init_cache()

      # First call hits the adapter
      assert {:ok, key} = TenantKeys.get_private_key(tenant.id)
      assert key == "fake-private-key-32bytes-padded!"
      assert_received {:secret_get, _}

      # Second call hits the cache — adapter NOT called again
      assert {:ok, ^key} = TenantKeys.get_private_key(tenant.id)
      assert :counters.get(call_count, 1) == 1
    end

    test "cross-tenant isolation" do
      tenant_a = fixture(:tenant, %{slug: "iso-a"})
      tenant_b = fixture(:tenant, %{slug: "iso-b"})

      Mox.expect(Loopctl.MockSecrets, :get, 2, fn name ->
        if String.ends_with?(name, "ISO_A") do
          {:ok, "key-a"}
        else
          {:ok, "key-b"}
        end
      end)

      TenantKeys.init_cache()

      assert {:ok, "key-a"} = TenantKeys.get_private_key(tenant_a.id)
      assert {:ok, "key-b"} = TenantKeys.get_private_key(tenant_b.id)
    end
  end

  describe "rotate_audit_key/2" do
    test "broadcasts the cluster invalidation, so peers stop signing with the retired key" do
      # #638 gave `TenantKeys` a cross-node bridge, and both halves were covered:
      # `invalidate_cluster/1` broadcasts, and the supervised owner busts on
      # receipt. NOTHING covered the WIRING — deleting this call site from
      # `rotate_audit_key/2` left the full suite green, so the fix could have been
      # refactored away silently. That is the whole failure it exists to prevent:
      # a peer keeps signing with the RETIRED key, and `signing_keys/2` admits a
      # historical key only for the window it was live, so the token verifies as
      # `:invalid_signature` and is chained as `capability_forged`,
      # `byzantine: true` — a benign rotation manufacturing forgery evidence.
      tenant = fixture(:tenant)

      tenant =
        tenant
        |> Ecto.Changeset.change(audit_signing_public_key: :crypto.strong_rand_bytes(32))
        |> AdminRepo.update!()

      Mox.expect(Loopctl.MockSecrets, :set, fn _name, _value -> :ok end)
      :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, "tenant_keys:invalidate")

      assert {:ok, _updated} =
               Tenants.rotate_audit_key(tenant.id, :crypto.strong_rand_bytes(64))

      tenant_id = tenant.id
      assert_receive {:invalidate, ^tenant_id}
    end

    test "busts the api_key cache, whose snapshots carry the tenant's audit public key" do
      # The SECOND untested wiring on this path (US-33.3). Cached api_key
      # snapshots embed `audit_signing_public_key`, so a rotation leaves every
      # cached key advertising the RETIRED public half — which is what the
      # capability verifier checks a signature against. Deleting this call site
      # also left the full suite green.
      tenant = fixture(:tenant)

      tenant =
        tenant
        |> Ecto.Changeset.change(audit_signing_public_key: :crypto.strong_rand_bytes(32))
        |> AdminRepo.update!()

      {_raw, api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :user, name: "rotate-cache"})

      Mox.expect(Loopctl.MockSecrets, :set, fn _name, _value -> :ok end)
      :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, "auth:api_key_cache:invalidate")

      assert {:ok, _updated} =
               Tenants.rotate_audit_key(tenant.id, :crypto.strong_rand_bytes(64))

      key_hash = api_key.key_hash
      assert_receive {:invalidate, ^key_hash}
    end

    test "rotates the key, archives the old one, and writes audit entry" do
      # Create tenant with an initial audit key
      tenant = fixture(:tenant, %{slug: "rotate-me"})

      old_pub = :crypto.strong_rand_bytes(32)

      tenant =
        tenant
        |> Ecto.Changeset.change(audit_signing_public_key: old_pub)
        |> Loopctl.AdminRepo.update!()

      Mox.expect(Loopctl.MockSecrets, :set, fn _name, _value -> :ok end)

      assertion_sig = :crypto.strong_rand_bytes(64)

      assert {:ok, updated} = Tenants.rotate_audit_key(tenant.id, assertion_sig)

      # New public key is different from old
      assert updated.audit_signing_public_key != old_pub
      assert byte_size(updated.audit_signing_public_key) == 32
      assert updated.audit_key_rotated_at != nil

      # Old key archived in history
      import Ecto.Query
      alias Loopctl.Tenants.AuditKeyHistory

      [history] =
        from(h in AuditKeyHistory, where: h.tenant_id == ^tenant.id)
        |> Loopctl.AdminRepo.all()

      assert history.public_key == old_pub
      assert history.rotated_out != nil
      assert history.rotation_signature == assertion_sig

      # Audit entry written
      alias Loopctl.Audit.AuditLog

      [audit] =
        from(a in AuditLog,
          where: a.tenant_id == ^tenant.id and a.action == "key_rotated",
          limit: 1
        )
        |> Loopctl.AdminRepo.all()

      assert audit.new_state["old_public_key"] == Base.encode64(old_pub)
    end

    test "rotation without existing key returns error" do
      tenant = fixture(:tenant)
      assert {:error, :no_existing_key} = Tenants.rotate_audit_key(tenant.id, <<>>)
    end

    # Review #2 — rotate OVERWRITES the deterministic secret with the NEW key.
    # A post-write rollback must RESTORE the OLD private key (not delete) so the
    # DB's rolled-back OLD public key still verifies.
    test "post-write failure RESTORES the old secret value (review #2)" do
      slug = "rotate-restore-#{System.unique_integer([:positive])}"
      tenant = fixture(:tenant, %{slug: slug})
      old_priv = :crypto.strong_rand_bytes(32)
      old_pub = :crypto.strong_rand_bytes(32)
      test_pid = self()

      tenant =
        tenant
        |> Ecto.Changeset.change(audit_signing_public_key: old_pub)
        |> AdminRepo.update!()

      # Pre-rotation read of the OLD private key (the lexical value used to restore).
      Mox.expect(Loopctl.MockSecrets, :get, fn _name -> {:ok, old_priv} end)

      # :set is called TWICE, in order:
      #   1. :store_new_secret writes the NEW key — then we blow up a LATER step
      #      by deleting the tenant so :update_tenant raises StaleEntryError.
      #   2. compensation RESTORES the OLD private key.
      Mox.expect(Loopctl.MockSecrets, :set, fn _name, new_priv ->
        assert new_priv != old_priv
        AdminRepo.query!("DELETE FROM tenants WHERE slug = $1", [slug])
        :ok
      end)

      Mox.expect(Loopctl.MockSecrets, :set, fn name, restored ->
        send(test_pid, {:restored, name, restored})
        :ok
      end)

      assert_raise Ecto.StaleEntryError, fn ->
        Tenants.rotate_audit_key(tenant.id, :crypto.strong_rand_bytes(64))
      end

      secret_name = Secrets.audit_key_secret_name(slug)
      # Restored with the OLD private key, NOT deleted.
      assert_received {:restored, ^secret_name, ^old_priv}
    end
  end

  describe "bootstrap_audit_key/1 (review #2)" do
    test "post-write failure DELETES the just-written secret" do
      slug = "bootstrap-del-#{System.unique_integer([:positive])}"
      tenant = fixture(:tenant, %{slug: slug})
      test_pid = self()

      # store_secret writes the key, then we blow up :set_public_key by deleting
      # the tenant row (bootstrap means NO prior key existed → compensate by delete).
      Mox.expect(Loopctl.MockSecrets, :set, fn _name, _priv ->
        AdminRepo.query!("DELETE FROM tenants WHERE slug = $1", [slug])
        :ok
      end)

      Mox.expect(Loopctl.MockSecrets, :delete, fn name ->
        send(test_pid, {:deleted, name})
        :ok
      end)

      assert_raise Ecto.StaleEntryError, fn ->
        Tenants.bootstrap_audit_key(tenant.id)
      end

      secret_name = Secrets.audit_key_secret_name(slug)
      assert_received {:deleted, ^secret_name}
    end

    test "busts the cached miss, so a peer stops refusing a tenant that now HAS a key" do
      tenant = fixture(:tenant)
      secret_name = Secrets.audit_key_secret_name(tenant.slug)
      test_pid = self()

      # A keyless tenant answers `:not_found`, and that failure is cached ON
      # PURPOSE: `Dispatches.verifier_seed/2` asks on every request-review, so an
      # uncached miss is a permanent storm against a 3-connection pool.
      Mox.stub(Loopctl.MockSecrets, :get, fn ^secret_name -> {:error, :not_found} end)
      assert {:error, :not_found} = TenantKeys.get_private_key(tenant.id)

      Mox.expect(Loopctl.MockSecrets, :set, fn ^secret_name, priv ->
        send(test_pid, {:stored, priv})
        :ok
      end)

      assert {:ok, _tenant} = Tenants.bootstrap_audit_key(tenant.id)
      assert_received {:stored, priv}

      # The store now HAS the key. Without the bust, the cached `:not_found`
      # keeps answering until the negative TTL lapses — and `verifier_seed/2`
      # fails CLOSED on it, so a story is flagged `verifier_needed` on the very
      # tenant that was just made able to verify.
      Mox.stub(Loopctl.MockSecrets, :get, fn ^secret_name -> {:ok, Base.encode64(priv)} end)
      assert {:ok, ^priv} = TenantKeys.get_private_key(tenant.id)
    end
  end
end
