defmodule Loopctl.Repo.RlsTest do
  # RLS tests are not async because they need shared sandbox mode
  # for cross-repo data visibility between Repo and AdminRepo.
  use Loopctl.DataCase, async: false

  setup :verify_on_exit!

  alias Ecto.Adapters.SQL
  alias Ecto.UUID
  alias Loopctl.AdminRepo
  alias Loopctl.Repo
  alias Loopctl.Repo.RlsTestRecord
  alias Loopctl.Tenants.Tenant

  defp create_tenant(name) do
    %Tenant{
      id: UUID.generate(),
      name: name,
      slug: "#{name}-#{System.unique_integer([:positive])}",
      email: "#{name}@example.com",
      status: :active
    }
    |> Repo.insert!()
  end

  defp insert_record_bypass_rls(tenant_id, name) do
    # Insert directly via raw SQL on the same Repo connection.
    # The postgres superuser bypasses RLS, so the insert succeeds
    # even without setting the tenant context.
    now = DateTime.utc_now()
    id = UUID.dump!(UUID.generate())
    tenant_id_bin = UUID.dump!(tenant_id)

    SQL.query!(
      Repo,
      """
      INSERT INTO rls_test_records (id, tenant_id, name, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5)
      """,
      [id, tenant_id_bin, name, now, now]
    )
  end

  defp set_non_superuser_role do
    # Switch to the non-superuser role so RLS is enforced.
    # This simulates the production environment where Repo
    # connects as loopctl_app (non-superuser).
    rls_role = Application.get_env(:loopctl, :rls_role, "loopctl_app")
    SQL.query!(Repo, "SET LOCAL ROLE #{rls_role}", [])
  end

  defp reset_role do
    SQL.query!(Repo, "RESET ROLE", [])
  end

  describe "put_tenant_id/1 and get_tenant_id/0" do
    test "stores and retrieves tenant_id from process dictionary" do
      tenant_id = UUID.generate()
      assert :ok = Repo.put_tenant_id(tenant_id)
      assert Repo.get_tenant_id() == tenant_id
    end

    test "returns nil when no tenant is set" do
      Repo.clear_tenant_id()
      assert Repo.get_tenant_id() == nil
    end

    test "clear_tenant_id/0 removes tenant from process dictionary" do
      Repo.put_tenant_id(UUID.generate())
      assert :ok = Repo.clear_tenant_id()
      assert Repo.get_tenant_id() == nil
    end
  end

  describe "with_tenant/2" do
    test "SET LOCAL sets tenant context for current transaction" do
      tenant = create_tenant("set-local-test")

      {:ok, result} =
        Repo.with_tenant(tenant.id, fn ->
          %{rows: [[setting]]} =
            SQL.query!(
              Repo,
              "SELECT current_setting('app.current_tenant_id', true)"
            )

          setting
        end)

      assert result == tenant.id
    end

    test "RLS prevents cross-tenant data access" do
      tenant_a = create_tenant("rls-a")
      tenant_b = create_tenant("rls-b")

      insert_record_bypass_rls(tenant_a.id, "record-a")
      insert_record_bypass_rls(tenant_b.id, "record-b")

      # Tenant A should only see their own record
      {:ok, records_a} =
        Repo.with_tenant(tenant_a.id, fn ->
          Repo.all(RlsTestRecord)
        end)

      assert length(records_a) == 1
      assert hd(records_a).name == "record-a"
      assert hd(records_a).tenant_id == tenant_a.id

      # Tenant B should only see their own record
      {:ok, records_b} =
        Repo.with_tenant(tenant_b.id, fn ->
          Repo.all(RlsTestRecord)
        end)

      assert length(records_b) == 1
      assert hd(records_b).name == "record-b"
      assert hd(records_b).tenant_id == tenant_b.id
    end

    test "query without tenant context returns empty results when RLS enforced" do
      tenant = create_tenant("no-context")
      insert_record_bypass_rls(tenant.id, "isolated-record")

      # Simulate production: switch to non-superuser role so RLS is enforced
      set_non_superuser_role()

      # Without SET LOCAL tenant context, RLS policy returns no rows
      records = Repo.all(RlsTestRecord)
      assert records == []

      reset_role()
    end
  end

  describe "AdminRepo bypass" do
    test "AdminRepo sees all tenant data via BYPASSRLS" do
      # Insert tenants via AdminRepo's own sandbox connection
      tenant_a =
        %Tenant{
          id: UUID.generate(),
          name: "admin-a",
          slug: "admin-a-#{System.unique_integer([:positive])}",
          email: "admin-a@example.com",
          status: :active
        }
        |> AdminRepo.insert!()

      tenant_b =
        %Tenant{
          id: UUID.generate(),
          name: "admin-b",
          slug: "admin-b-#{System.unique_integer([:positive])}",
          email: "admin-b@example.com",
          status: :active
        }
        |> AdminRepo.insert!()

      # Insert records via AdminRepo (bypasses RLS as superuser)
      now = DateTime.utc_now()

      %RlsTestRecord{tenant_id: tenant_a.id, name: "admin-record-a"}
      |> RlsTestRecord.changeset(%{name: "admin-record-a"})
      |> Ecto.Changeset.put_change(:tenant_id, tenant_a.id)
      |> Ecto.Changeset.put_change(:inserted_at, now)
      |> Ecto.Changeset.put_change(:updated_at, now)
      |> AdminRepo.insert!()

      %RlsTestRecord{tenant_id: tenant_b.id, name: "admin-record-b"}
      |> RlsTestRecord.changeset(%{name: "admin-record-b"})
      |> Ecto.Changeset.put_change(:tenant_id, tenant_b.id)
      |> Ecto.Changeset.put_change(:inserted_at, now)
      |> Ecto.Changeset.put_change(:updated_at, now)
      |> AdminRepo.insert!()

      # AdminRepo should see ALL data across tenants
      records = AdminRepo.all(RlsTestRecord)
      names = Enum.map(records, & &1.name)

      assert "admin-record-a" in names
      assert "admin-record-b" in names
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot access tenant B data" do
      tenant_a = create_tenant("iso-a")
      tenant_b = create_tenant("iso-b")

      insert_record_bypass_rls(tenant_a.id, "secret-a")
      insert_record_bypass_rls(tenant_b.id, "secret-b")

      {:ok, results} =
        Repo.with_tenant(tenant_a.id, fn ->
          Repo.all(RlsTestRecord)
        end)

      tenant_ids = Enum.map(results, & &1.tenant_id)
      refute tenant_b.id in tenant_ids
      assert Enum.all?(tenant_ids, &(&1 == tenant_a.id))
    end
  end

  describe "process isolation for tenant context" do
    test "concurrent tasks with different tenant contexts do not leak" do
      tenant_a = create_tenant("proc-iso-a")
      tenant_b = create_tenant("proc-iso-b")

      # Each task sets its own tenant and verifies it sees only its own ID
      task_a =
        Task.async(fn ->
          Repo.put_tenant_id(tenant_a.id)
          # Small sleep to increase chance of interleaving
          Process.sleep(10)
          Repo.get_tenant_id()
        end)

      task_b =
        Task.async(fn ->
          Repo.put_tenant_id(tenant_b.id)
          Process.sleep(10)
          Repo.get_tenant_id()
        end)

      result_a = Task.await(task_a)
      result_b = Task.await(task_b)

      # Each task must see only its own tenant — no cross-contamination
      assert result_a == tenant_a.id
      assert result_b == tenant_b.id

      # Parent process should not be affected by child tenant contexts
      Repo.clear_tenant_id()
      assert Repo.get_tenant_id() == nil
    end
  end
end
