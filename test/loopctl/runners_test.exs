defmodule Loopctl.RunnersTest do
  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Auth
  alias Loopctl.Runners
  alias Loopctl.Runners.Runner
  alias Loopctl.Tenants

  setup :verify_on_exit!

  describe "enroll_runner/3" do
    test "mints an :agent key bound to the machine name and records it on the audit chain" do
      tenant = fixture(:tenant)

      assert {:ok, %{runner: runner, raw_key: raw_key}} =
               Runners.enroll_runner(tenant.id, %{name: "minis"})

      assert runner.name == "minis"
      assert runner.tenant_id == tenant.id
      assert is_nil(runner.revoked_at)

      assert {:ok, api_key} = Auth.verify_api_key(raw_key)
      assert api_key.id == runner.api_key_id
      assert api_key.role == :agent
      assert api_key.tenant_id == tenant.id

      assert AdminRepo.exists?(
               from e in Entry,
                 where:
                   e.tenant_id == ^tenant.id and e.action == "runner_enrolled" and
                     e.entity_id == ^runner.id
             )
    end

    test "refuses a malformed name without minting a key" do
      tenant = fixture(:tenant)

      for bad <- ["", "Minis", "has space", "../etc", "-leading", String.duplicate("a", 64)] do
        assert {:error, %Ecto.Changeset{} = cs} = Runners.enroll_runner(tenant.id, %{name: bad})
        assert %{name: _} = errors_on(cs)
      end

      assert Auth.count_api_keys(tenant.id) == 0
    end

    test "refuses a second ACTIVE runner with the same name, and rolls its key back" do
      tenant = fixture(:tenant)
      {_raw, _runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis"})

      assert {:error, %Ecto.Changeset{} = cs} = Runners.enroll_runner(tenant.id, %{name: "minis"})
      assert "an active runner already uses this name" in errors_on(cs).name
      assert Auth.count_api_keys(tenant.id) == 1
    end

    test "allows re-enrolling a revoked machine under its old name" do
      tenant = fixture(:tenant)
      {_raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis"})
      {:ok, _} = Runners.revoke_runner(tenant.id, runner.id)

      assert {:ok, %{runner: again}} = Runners.enroll_runner(tenant.id, %{name: "minis"})
      assert again.id != runner.id
    end
  end

  describe "authenticate/1" do
    test "resolves an enrolled runner's token" do
      {raw, runner} = fixture(:runner, %{})
      assert {:ok, %{runner: %Runner{id: id}, api_key: key}} = Runners.authenticate(raw)
      assert id == runner.id
      assert key.id == runner.api_key_id
    end

    test "refuses garbage, empty and non-binary tokens" do
      assert {:error, :invalid_token} = Runners.authenticate("lc_not_a_key")
      assert {:error, :invalid_token} = Runners.authenticate("")
      assert {:error, :invalid_token} = Runners.authenticate(nil)
    end

    test "refuses a valid agent key that is not bound to a runner" do
      tenant = fixture(:tenant)
      {raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      assert {:error, :not_a_runner} = Runners.authenticate(raw)
    end

    test "refuses a valid key of any other role" do
      tenant = fixture(:tenant)

      for role <- [:user, :orchestrator] do
        {raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: role})
        assert {:error, :not_a_runner} = Runners.authenticate(raw)
      end
    end

    test "refuses a revoked runner at once, through the key cache" do
      {raw, runner} = fixture(:runner, %{})
      # Warm the positive cache entry first, so the refusal proves the cache was busted.
      assert {:ok, _} = Runners.authenticate(raw)

      {:ok, _} = Runners.revoke_runner(runner.tenant_id, runner.id)
      assert {:error, :invalid_token} = Runners.authenticate(raw)
    end

    test "refuses a runner whose tenant is suspended" do
      tenant = fixture(:tenant)
      {raw, _runner} = fixture(:runner, %{tenant_id: tenant.id})
      {:ok, _} = Tenants.suspend_tenant(tenant)
      Auth.invalidate_key_cache_by_hashes([Auth.hash_key(raw)])

      assert {:error, :tenant_inactive} = Runners.authenticate(raw)
    end
  end

  describe "revoke_runner/3" do
    test "revokes the row and the key, audits, and notifies the live channel" do
      {_raw, runner} = fixture(:runner, %{})
      :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, Runners.revocation_topic(runner.id))

      assert {:ok, revoked} = Runners.revoke_runner(runner.tenant_id, runner.id)
      assert revoked.revoked_at
      assert_receive :runner_revoked

      assert %{revoked_at: %DateTime{}} = AdminRepo.get!(Auth.ApiKey, runner.api_key_id)

      assert AdminRepo.exists?(
               from e in Entry,
                 where: e.action == "runner_revoked" and e.entity_id == ^runner.id
             )
    end

    test "is idempotent" do
      {_raw, runner} = fixture(:runner, %{})
      {:ok, first} = Runners.revoke_runner(runner.tenant_id, runner.id)
      assert {:ok, second} = Runners.revoke_runner(runner.tenant_id, runner.id)
      assert second.revoked_at == first.revoked_at
    end

    test "is not_found for a malformed id" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Runners.revoke_runner(tenant.id, "not-a-uuid")
    end
  end

  describe "the runner row follows its key" do
    test "revoking the key through the api_keys route revokes the runner, freeing its name" do
      tenant = fixture(:tenant)
      {_raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis"})
      {:ok, key} = Auth.get_api_key(tenant.id, runner.api_key_id)
      {:ok, _} = Auth.revoke_api_key(key)

      assert %Runner{revoked_at: %DateTime{}} = AdminRepo.get!(Runner, runner.id)
      assert Runners.list_runners(tenant.id) == []
      assert {:ok, _} = Runners.enroll_runner(tenant.id, %{name: "minis"})
    end

    test "revoking an unrelated key leaves every runner active" do
      tenant = fixture(:tenant)
      {_raw, runner} = fixture(:runner, %{tenant_id: tenant.id})
      {_raw_key, other} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {:ok, _} = Auth.revoke_api_key(other)

      assert is_nil(AdminRepo.get!(Runner, runner.id).revoked_at)
    end

    test "runner_key?/2 names a runner's key and nothing else, per tenant" do
      {_raw, runner} = fixture(:runner, %{})
      {_raw_key, plain} = fixture(:api_key, %{tenant_id: runner.tenant_id, role: :agent})

      assert Runners.runner_key?(runner.tenant_id, runner.api_key_id)
      refute Runners.runner_key?(runner.tenant_id, plain.id)
      refute Runners.runner_key?(fixture(:tenant).id, runner.api_key_id)
    end
  end

  describe "authorized?/2" do
    test "is true for an active runner" do
      {_raw, runner} = fixture(:runner, %{})
      assert Runners.authorized?(runner.tenant_id, runner.id)
    end

    test "is false once the runner is revoked" do
      {_raw, runner} = fixture(:runner, %{})
      {:ok, _} = Runners.revoke_runner(runner.tenant_id, runner.id)
      refute Runners.authorized?(runner.tenant_id, runner.id)
    end

    test "is false when the key is revoked by the api_keys route, not the runner route" do
      {_raw, runner} = fixture(:runner, %{})
      {:ok, key} = Auth.get_api_key(runner.tenant_id, runner.api_key_id)
      {:ok, _} = Auth.revoke_api_key(key)

      refute Runners.authorized?(runner.tenant_id, runner.id)
    end

    test "is false when the key has expired" do
      {_raw, runner} = fixture(:runner, %{})
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      from(k in Auth.ApiKey, where: k.id == ^runner.api_key_id)
      |> AdminRepo.update_all(set: [expires_at: past])

      refute Runners.authorized?(runner.tenant_id, runner.id)
    end

    test "is false when the tenant is suspended" do
      tenant = fixture(:tenant)
      {_raw, runner} = fixture(:runner, %{tenant_id: tenant.id})
      {:ok, _} = Tenants.suspend_tenant(tenant)

      refute Runners.authorized?(tenant.id, runner.id)
    end
  end

  describe "tenant isolation" do
    test "tenant B can neither see, fetch, revoke nor authorize tenant A's runner" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {_raw, runner_a} = fixture(:runner, %{tenant_id: tenant_a.id, name: "minis"})

      assert Runners.list_runners(tenant_b.id, include_revoked: true) == []
      assert {:error, :not_found} = Runners.get_runner(tenant_b.id, runner_a.id)
      assert {:error, :not_found} = Runners.revoke_runner(tenant_b.id, runner_a.id)
      refute Runners.authorized?(tenant_b.id, runner_a.id)

      assert [%Runner{id: id}] = Runners.list_runners(tenant_a.id)
      assert id == runner_a.id
      assert is_nil(AdminRepo.get!(Runner, runner_a.id).revoked_at)
    end

    test "two tenants may each enroll a machine of the same name" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {_raw, _a} = fixture(:runner, %{tenant_id: tenant_a.id, name: "minis"})

      assert {:ok, _} = Runners.enroll_runner(tenant_b.id, %{name: "minis"})
    end

    test "each tenant's pool topic is distinct" do
      assert Runners.pool_topic(Ecto.UUID.generate()) != Runners.pool_topic(Ecto.UUID.generate())
    end
  end
end
