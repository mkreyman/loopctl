defmodule Loopctl.SchemaTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  # Test schema: standard tenant-scoped
  defmodule TenantScoped do
    use Loopctl.Schema

    schema "test_tenant_scoped" do
      tenant_field()
      field :name, :string
      timestamps()
    end
  end

  # Test schema: non-tenant-scoped
  defmodule NonTenantScoped do
    use Loopctl.Schema, tenant_scoped: false

    schema "test_non_tenant_scoped" do
      field :name, :string
      timestamps()
    end
  end

  # Test schema: with soft delete
  defmodule SoftDeletable do
    use Loopctl.Schema, soft_delete: true

    schema "test_soft_deletable" do
      tenant_field()
      field :name, :string
      field :deleted_at, :utc_datetime_usec
      timestamps()
    end
  end

  # Test schema: without soft delete (default)
  defmodule NoSoftDelete do
    use Loopctl.Schema

    schema "test_no_soft_delete" do
      tenant_field()
      field :name, :string
      timestamps()
    end
  end

  describe "primary key configuration" do
    test "schema has binary_id primary key" do
      assert TenantScoped.__schema__(:primary_key) == [:id]

      assert TenantScoped.__schema__(:type, :id) == :binary_id
    end

    test "non-tenant-scoped schema also has binary_id primary key" do
      assert NonTenantScoped.__schema__(:primary_key) == [:id]
      assert NonTenantScoped.__schema__(:type, :id) == :binary_id
    end
  end

  describe "tenant_field/0" do
    test "tenant-scoped schema includes tenant_id field" do
      fields = TenantScoped.__schema__(:fields)
      assert :tenant_id in fields
    end

    test "tenant_id is a binary_id association" do
      assocs = TenantScoped.__schema__(:associations)
      assert :tenant in assocs

      assoc = TenantScoped.__schema__(:association, :tenant)
      assert assoc.related == Loopctl.Tenants.Tenant
    end

    test "non-tenant-scoped schema omits tenant_id" do
      fields = NonTenantScoped.__schema__(:fields)
      refute :tenant_id in fields
    end
  end

  describe "timestamps" do
    test "timestamps use utc_datetime_usec type" do
      assert TenantScoped.__schema__(:type, :inserted_at) == :utc_datetime_usec
      assert TenantScoped.__schema__(:type, :updated_at) == :utc_datetime_usec
    end

    test "non-tenant-scoped timestamps also use utc_datetime_usec" do
      assert NonTenantScoped.__schema__(:type, :inserted_at) == :utc_datetime_usec
      assert NonTenantScoped.__schema__(:type, :updated_at) == :utc_datetime_usec
    end
  end

  describe "soft delete" do
    test "soft_delete_changeset/1 sets deleted_at to current UTC time" do
      struct = %SoftDeletable{id: Ecto.UUID.generate(), name: "test"}
      changeset = Loopctl.Schema.soft_delete_changeset(struct)

      assert changeset.valid?
      deleted_at = Ecto.Changeset.get_change(changeset, :deleted_at)
      assert %DateTime{} = deleted_at
      assert deleted_at.time_zone == "Etc/UTC"

      # Should be within the last second
      diff = DateTime.diff(DateTime.utc_now(), deleted_at, :second)
      assert diff >= 0 and diff <= 1
    end

    test "schema with soft_delete: true has deleted_at field" do
      fields = SoftDeletable.__schema__(:fields)
      assert :deleted_at in fields
      assert SoftDeletable.__schema__(:type, :deleted_at) == :utc_datetime_usec
    end

    test "schema without soft_delete has no deleted_at field" do
      fields = NoSoftDelete.__schema__(:fields)
      refute :deleted_at in fields
    end
  end

  describe "not_deleted/1" do
    test "builds a query filtering out deleted records" do
      query = Loopctl.Schema.not_deleted(SoftDeletable)
      # Verify it produces a valid Ecto.Query
      assert %Ecto.Query{} = query
    end

    test "returns only non-deleted records from the database" do
      alias Loopctl.Repo.RlsTestRecord

      tenant = fixture(:tenant)

      {:ok, _active} =
        Repo.with_tenant(tenant.id, fn ->
          %RlsTestRecord{tenant_id: tenant.id}
          |> RlsTestRecord.changeset(%{name: "active-record"})
          |> Ecto.Changeset.put_change(:tenant_id, tenant.id)
          |> Repo.insert!()
        end)

      {:ok, _deleted} =
        Repo.with_tenant(tenant.id, fn ->
          %RlsTestRecord{tenant_id: tenant.id}
          |> RlsTestRecord.changeset(%{name: "deleted-record"})
          |> Ecto.Changeset.put_change(:tenant_id, tenant.id)
          |> Ecto.Changeset.put_change(:deleted_at, ~U[2024-01-01 00:00:00.000000Z])
          |> Repo.insert!()
        end)

      {:ok, results} =
        Repo.with_tenant(tenant.id, fn ->
          RlsTestRecord
          |> Loopctl.Schema.not_deleted()
          |> Repo.all()
        end)

      assert length(results) == 1
      assert hd(results).name == "active-record"
    end
  end

  describe "tenant_id validation" do
    test "RlsTestRecord requires tenant_id for database insertion" do
      alias Loopctl.Repo.RlsTestRecord

      # A record without tenant_id should fail on DB insert due to NOT NULL constraint
      changeset =
        %RlsTestRecord{}
        |> RlsTestRecord.changeset(%{name: "no-tenant"})

      assert changeset.valid?

      assert_raise Postgrex.Error, fn ->
        Repo.insert!(changeset)
      end
    end
  end

  describe "timestamp precision" do
    test "timestamps preserve microsecond precision via DB round-trip" do
      alias Loopctl.Repo.RlsTestRecord

      tenant = fixture(:tenant)

      {:ok, inserted} =
        Repo.with_tenant(tenant.id, fn ->
          %RlsTestRecord{tenant_id: tenant.id}
          |> RlsTestRecord.changeset(%{name: "precision-test"})
          |> Ecto.Changeset.put_change(:tenant_id, tenant.id)
          |> Repo.insert!()
        end)

      {:ok, [fetched]} =
        Repo.with_tenant(tenant.id, fn ->
          Repo.all(RlsTestRecord)
        end)

      # Verify microsecond precision is preserved (not truncated to seconds)
      assert fetched.inserted_at.microsecond != {0, 0}
      assert {_usec, 6} = fetched.inserted_at.microsecond
      assert {_usec, 6} = fetched.updated_at.microsecond

      # Verify round-trip preserves the exact value
      assert fetched.inserted_at == inserted.inserted_at
      assert fetched.updated_at == inserted.updated_at
    end
  end
end
