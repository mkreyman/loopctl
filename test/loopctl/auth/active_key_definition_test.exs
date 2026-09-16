defmodule Loopctl.Auth.ActiveKeyDefinitionTest do
  use Loopctl.DataCase, async: true

  @moduledoc """
  846.8 review round 2, finding 3. `Loopctl.Auth.active_api_keys_query/0` calls itself THE ONE
  DEFINITION of an active api_key, and three things have to agree with it or the claim is a
  sentence rather than a fact:

    * `load_active_api_key/1` — the uncached read a request is judged by. It now COMPOSES over
      the query, so that half is structural and this file only has to prove the composition
      did not lose a clause.
    * `valid_now?/1` — the same rule in Elixir, applied on a cache HIT where no SQL ran. It
      cannot compose over a query and never will, so holding the two against each other row by
      row is the only binding available.
    * `verify_api_key/1` — the caller-visible answer, which routes through one or the other
      depending on the cache.

  The four rows below are the boundary: revoked, expired, expiring in the future, and never
  expiring. Each is asserted three ways against the SAME expectation, so a change to any one
  encoding that the others do not follow fails here.

  THE KEYS ARE `:user`-ROLE WITH NO AGENT on purpose, as in
  `test/loopctl/tenants/active_api_key_counts_test.exs`:
  `Loopctl.Workers.RevokeExpiredApiKeysWorker` never revokes those, so an expired one stays
  `revoked_at IS NULL` for ever and the two notions of "active" can actually be told apart.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey

  describe "the SQL definition and the in-memory one answer identically" do
    test "over every boundary shape a key can be in" do
      tenant = fixture(:tenant)

      rows = [
        {"revoked", :revoked, false},
        {"expired", :expired, false},
        {"future expiry", :future, true},
        {"no expiry", :never, true}
      ]

      for {label, shape, expected_active} <- rows do
        {raw, key} = build_key(tenant.id, label, shape)

        assert in_query?(key) == expected_active,
               "active_api_keys_query/0 disagrees on a #{label} key"

        assert Auth.valid_now?(reload(key)) == expected_active,
               "valid_now?/1 disagrees with active_api_keys_query/0 on a #{label} key"

        assert authenticates?(raw) == expected_active,
               "verify_api_key/1 disagrees with active_api_keys_query/0 on a #{label} key"
      end
    end

    test "the expectations are not all the same, so agreement is not vacuous" do
      # Without this, an encoding that answered `true` for everything would satisfy the test
      # above as long as the other two did too. Both verdicts have to be represented.
      tenant = fixture(:tenant)

      {_raw, revoked} = build_key(tenant.id, "r", :revoked)
      {_raw, live} = build_key(tenant.id, "l", :never)

      refute in_query?(revoked)
      assert in_query?(live)
    end

    test "a cache HIT is judged by valid_now?/1, and reaches the same verdict as the query" do
      # The path `valid_now?/1` exists for. The first call misses the cache and goes through
      # `load_active_api_key/1`; the second is served from the cache, where no SQL runs at all.
      # A key that is active by the query must authenticate on BOTH, or the two encodings
      # disagree exactly where nobody would notice.
      tenant = fixture(:tenant)
      {raw, key} = build_key(tenant.id, "warm", :future)

      assert in_query?(key)
      assert authenticates?(raw)
      assert authenticates?(raw)
    end
  end

  defp build_key(tenant_id, name, shape) do
    {raw, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :user, name: name})

    case shape do
      :revoked ->
        {:ok, key} = Auth.revoke_api_key(key)
        {raw, key}

      :expired ->
        {:ok, key} = Auth.expire_api_key(key, DateTime.add(DateTime.utc_now(), -3600, :second))
        {raw, key}

      :future ->
        {:ok, key} = Auth.expire_api_key(key, DateTime.add(DateTime.utc_now(), 3600, :second))
        {raw, key}

      :never ->
        {raw, key}
    end
  end

  defp in_query?(%ApiKey{id: id}) do
    from(k in Auth.active_api_keys_query(), where: k.id == ^id, select: count(k.id))
    |> AdminRepo.one()
    |> Kernel.==(1)
  end

  defp reload(%ApiKey{id: id}), do: AdminRepo.get!(ApiKey, id)

  defp authenticates?(raw) do
    match?({:ok, _}, Auth.verify_api_key(raw))
  end
end
