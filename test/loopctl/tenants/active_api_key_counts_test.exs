defmodule Loopctl.Tenants.ActiveApiKeyCountsTest do
  use Loopctl.DataCase, async: true

  @moduledoc """
  846.8 AC-2. The operator-facing "active keys" counts answer "how many keys can
  authenticate right now", and the auth pipeline's answer to that is
  `Loopctl.Auth.load_active_api_key/1`: not revoked AND not past its expiry. Both counters
  tested `revoked_at IS NULL` alone, so every expired-but-unrevoked key inflated them.

  `Loopctl.Workers.RevokeExpiredApiKeysWorker` does NOT close this. It deliberately never
  touches a `user`/`superadmin` key, nor any key with a NULL `agent_id` — revoking those
  destroys the rotate path and frees no `api_keys_one_role_per_agent_idx` slot — so for
  exactly those keys the two notions never converge. That is why the SEED here is a
  `:user`-role key with no agent: a test seeded only with unexpired keys, or with keys the
  sweep would revoke within a minute anyway, cannot tell the two definitions apart.
  """

  alias Loopctl.Auth
  alias Loopctl.Tenants

  # FUNCTIONS, NOT MODULE ATTRIBUTES. An attribute is evaluated once, when ExUnit LOADS this
  # file, so on a full-suite run that takes more than an hour to reach these tests the
  # "expires in the FUTURE" key has already expired by the time it is written — and the
  # positive control fails for a reason that has nothing to do with the counter it is
  # guarding. An hour is not a hypothetical margin here; it is roughly this suite.
  #
  # An hour either way, so no clock skew inside an assertion window can move a key across
  # the boundary.
  defp past_expiry, do: DateTime.add(DateTime.utc_now(), -3600, :second)
  defp future_expiry, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  describe "tenant_with_stats api_key_count (get_tenant_admin/1, list_tenants_admin/1)" do
    test "an expired but UNREVOKED key is not counted as active" do
      tenant = fixture(:tenant)
      {_raw, expired} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      {:ok, expired} = Auth.expire_api_key(expired, past_expiry())

      # The row is still un-revoked — this is the state the sweep leaves behind for ever,
      # so without an expiry term in the counter it reads as active.
      refute expired.revoked_at
      assert {:ok, stats} = Tenants.get_tenant_admin(tenant.id)
      assert stats.api_key_count == 0
    end

    test "a key expiring in the FUTURE and a key with no expiry are both counted" do
      # The positive control. Without it the assertion above is satisfied by a counter
      # that returns zero for everything.
      tenant = fixture(:tenant)
      {_raw, future} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      {:ok, _future} = Auth.expire_api_key(future, future_expiry())
      {_raw, _never} = fixture(:api_key, tenant_id: tenant.id, role: :agent)

      assert {:ok, stats} = Tenants.get_tenant_admin(tenant.id)
      assert stats.api_key_count == 2
    end

    test "a revoked key is still not counted (the original predicate is kept, not replaced)" do
      tenant = fixture(:tenant)
      {_raw, revoked} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      {:ok, _} = Auth.revoke_api_key(revoked)

      assert {:ok, stats} = Tenants.get_tenant_admin(tenant.id)
      assert stats.api_key_count == 0
    end

    test "list_tenants_admin/1 answers the same, since it shares the predicate" do
      tenant = fixture(:tenant)
      {_raw, expired} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      {:ok, _} = Auth.expire_api_key(expired, past_expiry())
      {_raw, _live} = fixture(:api_key, tenant_id: tenant.id, role: :agent)

      assert {:ok, %{data: rows}} = Tenants.list_tenants_admin(search: tenant.slug)
      assert [%{api_key_count: 1}] = Enum.filter(rows, &(&1.tenant.id == tenant.id))
    end

    test "the count is tenant-scoped: another tenant's live key is not counted here" do
      tenant = fixture(:tenant)
      other = fixture(:tenant)
      {_raw, _theirs} = fixture(:api_key, tenant_id: other.id, role: :agent)

      assert {:ok, stats} = Tenants.get_tenant_admin(tenant.id)
      assert stats.api_key_count == 0
    end
  end

  describe "system_stats/0 total_api_keys" do
    # Cross-tenant by construction, so assert on the DELTA this test causes rather than on
    # an absolute the rest of the suite would have to agree about.
    test "an expired but unrevoked key does not move the total; a live one does" do
      before = total_api_keys()

      tenant = fixture(:tenant)
      {_raw, expired} = fixture(:api_key, tenant_id: tenant.id, role: :user)
      {:ok, _} = Auth.expire_api_key(expired, past_expiry())

      assert total_api_keys() == before

      {_raw, _live} = fixture(:api_key, tenant_id: tenant.id, role: :agent)

      assert total_api_keys() == before + 1
    end
  end

  defp total_api_keys do
    {:ok, stats} = Tenants.system_stats()
    stats.total_api_keys
  end
end
