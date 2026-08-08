defmodule Loopctl.TenantKeysTest do
  @moduledoc """
  The tenant audit-key cache, and specifically its NEGATIVE half.

  `Dispatches.verifier_seed/2` asks for this key on every `request-review`, and it is
  the only value standing between deterministic verifier selection and predictable
  verifier selection. Successes were cached and failures were not, so a secret-store
  outage cost one round trip per call deployment-wide — the outage amplifying load
  against the store that was already failing, and the retry storm outliving it.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.TenantKeys

  setup :verify_on_exit!

  defp count_calls(name) do
    parent = self()

    Mox.stub(Loopctl.MockSecrets, :get, fn ^name ->
      send(parent, :secret_get)
      {:error, :unreachable}
    end)
  end

  defp drain(acc \\ 0) do
    receive do
      :secret_get -> drain(acc + 1)
    after
      0 -> acc
    end
  end

  describe "negative caching" do
    test "a secret-store failure is fetched ONCE across repeated lookups" do
      tenant = fixture(:tenant)
      count_calls(Loopctl.Secrets.audit_key_secret_name(tenant.slug))

      assert {:error, :unreachable} = TenantKeys.get_private_key(tenant.id)
      assert {:error, :unreachable} = TenantKeys.get_private_key(tenant.id)
      assert {:error, :unreachable} = TenantKeys.get_private_key(tenant.id)

      assert drain() == 1
    end

    test "a missing tenant is cached too, and never mistaken for a key" do
      missing = Ecto.UUID.generate()

      assert {:error, :tenant_not_found} = TenantKeys.get_private_key(missing)
      assert {:error, :tenant_not_found} = TenantKeys.get_private_key(missing)
    end

    test "invalidate/1 clears a cached failure, so provisioning a key takes effect at once" do
      tenant = fixture(:tenant)
      secret_name = Loopctl.Secrets.audit_key_secret_name(tenant.slug)
      count_calls(secret_name)

      assert {:error, :unreachable} = TenantKeys.get_private_key(tenant.id)

      # The tenant earns an audit key (rotation, or the enrollment upgrade). Both call
      # `invalidate/1`; without that the tenant would wait out the negative TTL while
      # its verifier selection reported `verifier_seed_unavailable`.
      key = :crypto.strong_rand_bytes(32)
      Mox.stub(Loopctl.MockSecrets, :get, fn ^secret_name -> {:ok, Base.encode64(key)} end)
      :ok = TenantKeys.invalidate(tenant.id)

      assert {:ok, ^key} = TenantKeys.get_private_key(tenant.id)
    end

    test "an absent key is cached too — the miss that repeats forever — and invalidate/1 busts it" do
      tenant = fixture(:tenant)
      secret_name = Loopctl.Secrets.audit_key_secret_name(tenant.slug)
      key = :crypto.strong_rand_bytes(32)
      parent = self()

      Mox.stub(Loopctl.MockSecrets, :get, fn ^secret_name ->
        send(parent, :secret_get)
        {:error, :not_found}
      end)

      # A tenant with no audit key answers :not_found on EVERY request-review for as long
      # as it has none. Leaving that uncached puts an AdminRepo query on the 3-connection
      # pool per call, permanently — the storm this cache exists to collapse.
      assert {:error, :not_found} = TenantKeys.get_private_key(tenant.id)
      assert {:error, :not_found} = TenantKeys.get_private_key(tenant.id)
      assert drain() == 1

      Mox.stub(Loopctl.MockSecrets, :get, fn ^secret_name -> {:ok, Base.encode64(key)} end)
      :ok = TenantKeys.invalidate(tenant.id)

      assert {:ok, ^key} = TenantKeys.get_private_key(tenant.id)
    end

    test "a failure from a fetch that a rotation overtook does not poison the new key" do
      tenant = fixture(:tenant)
      secret_name = Loopctl.Secrets.audit_key_secret_name(tenant.slug)
      key = :crypto.strong_rand_bytes(32)

      # The rotation lands while this fetch is IN FLIGHT: `invalidate/1` deletes the row,
      # then the slow failure writes its negative entry onto the now-empty table — so
      # `insert_new` succeeds and, without the epoch, the entry stands for the full TTL.
      Mox.stub(Loopctl.MockSecrets, :get, fn ^secret_name ->
        :ok = TenantKeys.invalidate(tenant.id)
        {:error, :unreachable}
      end)

      assert {:error, :unreachable} = TenantKeys.get_private_key(tenant.id)

      Mox.stub(Loopctl.MockSecrets, :get, fn ^secret_name -> {:ok, Base.encode64(key)} end)

      # Capability minting and verifier selection would otherwise fail for 15s on a
      # tenant whose key is perfectly valid and freshly rotated.
      assert {:ok, ^key} = TenantKeys.get_private_key(tenant.id)
    end

    test "a cached SUCCESS is still returned as {:ok, key}" do
      tenant = fixture(:tenant)
      secret_name = Loopctl.Secrets.audit_key_secret_name(tenant.slug)
      key = :crypto.strong_rand_bytes(32)
      parent = self()

      Mox.stub(Loopctl.MockSecrets, :get, fn ^secret_name ->
        send(parent, :secret_get)
        {:ok, Base.encode64(key)}
      end)

      assert {:ok, ^key} = TenantKeys.get_private_key(tenant.id)
      assert {:ok, ^key} = TenantKeys.get_private_key(tenant.id)

      assert drain() == 1
    end
  end

  describe "tenant isolation" do
    test "a cached failure for tenant A does not answer for tenant B" do
      a = fixture(:tenant)
      b = fixture(:tenant)
      key = :crypto.strong_rand_bytes(32)
      b_secret = Loopctl.Secrets.audit_key_secret_name(b.slug)

      Mox.stub(Loopctl.MockSecrets, :get, fn
        ^b_secret -> {:ok, Base.encode64(key)}
        _other -> {:error, :unreachable}
      end)

      assert {:error, :unreachable} = TenantKeys.get_private_key(a.id)
      assert {:ok, ^key} = TenantKeys.get_private_key(b.id)
    end
  end
end
