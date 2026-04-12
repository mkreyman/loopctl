defmodule Loopctl.TenantsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Tenants
  alias Loopctl.Tenants.Tenant

  describe "create_tenant/1" do
    test "creates tenant with valid attributes" do
      attrs = %{name: "Acme Corp", slug: "acme-corp", email: "admin@acme.com"}

      assert {:ok, %Tenant{} = tenant} = Tenants.create_tenant(attrs)
      assert tenant.name == "Acme Corp"
      assert tenant.slug == "acme-corp"
      assert tenant.email == "admin@acme.com"
      assert tenant.status == :active
      assert tenant.settings == %{}
      assert is_binary(tenant.id)
    end

    test "creates tenant with custom settings" do
      attrs = %{
        name: "Custom Corp",
        slug: "custom-corp",
        email: "admin@custom.com",
        settings: %{"max_projects" => 10}
      }

      assert {:ok, %Tenant{} = tenant} = Tenants.create_tenant(attrs)
      assert tenant.settings == %{"max_projects" => 10}
    end

    test "rejects duplicate slug" do
      fixture(:tenant, %{slug: "acme-corp"})

      attrs = %{name: "Other Corp", slug: "acme-corp", email: "other@example.com"}
      assert {:error, changeset} = Tenants.create_tenant(attrs)
      assert "has already been taken" in errors_on(changeset).slug
    end

    test "rejects invalid slug format - uppercase" do
      attrs = %{name: "Test", slug: "INVALID-SLUG", email: "test@test.com"}
      assert {:error, changeset} = Tenants.create_tenant(attrs)
      assert errors_on(changeset).slug != []
    end

    test "rejects invalid slug format - too short" do
      attrs = %{name: "Test", slug: "a", email: "test@test.com"}
      assert {:error, changeset} = Tenants.create_tenant(attrs)
      assert errors_on(changeset).slug != []
    end

    test "rejects invalid slug format - spaces" do
      attrs = %{name: "Test", slug: "invalid slug", email: "test@test.com"}
      assert {:error, changeset} = Tenants.create_tenant(attrs)
      assert errors_on(changeset).slug != []
    end

    test "rejects invalid email format" do
      attrs = %{name: "Test", slug: "test-tenant", email: "not-an-email"}
      assert {:error, changeset} = Tenants.create_tenant(attrs)
      assert errors_on(changeset).email != []
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = Tenants.create_tenant(%{})
      errors = errors_on(changeset)
      assert errors.name != []
      assert errors.slug != []
      assert errors.email != []
    end
  end

  describe "get_tenant/1" do
    test "returns tenant by ID" do
      tenant = fixture(:tenant)
      assert {:ok, found} = Tenants.get_tenant(tenant.id)
      assert found.id == tenant.id
    end

    test "returns not_found for unknown ID" do
      assert {:error, :not_found} = Tenants.get_tenant(Ecto.UUID.generate())
    end
  end

  describe "get_tenant_by_slug/1" do
    test "returns tenant by slug" do
      tenant = fixture(:tenant, %{slug: "test-slug"})
      assert {:ok, found} = Tenants.get_tenant_by_slug("test-slug")
      assert found.id == tenant.id
    end

    test "returns not_found for unknown slug" do
      assert {:error, :not_found} = Tenants.get_tenant_by_slug("nonexistent")
    end
  end

  describe "update_tenant/2" do
    test "updates tenant with valid attributes" do
      tenant = fixture(:tenant, %{settings: %{}})

      assert {:ok, updated} =
               Tenants.update_tenant(tenant, %{
                 settings: %{"rate_limit_requests_per_minute" => 500}
               })

      assert updated.settings == %{"rate_limit_requests_per_minute" => 500}
    end

    test "updates tenant name" do
      tenant = fixture(:tenant)
      assert {:ok, updated} = Tenants.update_tenant(tenant, %{name: "New Name"})
      assert updated.name == "New Name"
    end
  end

  describe "list_tenants/1" do
    test "returns all tenants ordered by name" do
      fixture(:tenant, %{name: "Zeta Corp"})
      fixture(:tenant, %{name: "Alpha Corp"})

      assert {:ok, tenants} = Tenants.list_tenants()
      names = Enum.map(tenants, & &1.name)
      assert "Alpha Corp" in names
      assert "Zeta Corp" in names
      # Alphabetical order: Alpha before Zeta
      alpha_idx = Enum.find_index(names, &(&1 == "Alpha Corp"))
      zeta_idx = Enum.find_index(names, &(&1 == "Zeta Corp"))
      assert alpha_idx < zeta_idx
    end

    test "filters by status" do
      fixture(:tenant, %{name: "Active One"})
      suspended = fixture(:tenant, %{name: "Suspended One"})
      Tenants.suspend_tenant(suspended)

      assert {:ok, active_tenants} = Tenants.list_tenants(status: :active)
      statuses = Enum.map(active_tenants, & &1.status)
      assert Enum.all?(statuses, &(&1 == :active))
    end
  end

  describe "suspend_tenant/1 and activate_tenant/1" do
    test "suspends an active tenant" do
      tenant = fixture(:tenant)
      assert {:ok, suspended} = Tenants.suspend_tenant(tenant)
      assert suspended.status == :suspended
    end

    test "activates a suspended tenant" do
      tenant = fixture(:tenant)
      {:ok, suspended} = Tenants.suspend_tenant(tenant)
      assert {:ok, activated} = Tenants.activate_tenant(suspended)
      assert activated.status == :active
    end
  end

  describe "list_tenants_admin/1" do
    test "search escapes LIKE metacharacters" do
      # Create tenants with names containing LIKE special characters
      fixture(:tenant, %{name: "100% Complete"})
      fixture(:tenant, %{name: "Just Normal"})

      # Searching for "100%" should only match the tenant with "100%" in the name,
      # not match all tenants (which would happen if % is not escaped)
      {:ok, result} = Tenants.list_tenants_admin(search: "100%")
      names = Enum.map(result.data, & &1.tenant.name)
      assert "100% Complete" in names
      refute "Just Normal" in names
    end

    test "search escapes underscore metacharacter" do
      fixture(:tenant, %{name: "a_b_c Corp"})
      fixture(:tenant, %{name: "axbxc Corp"})

      # Searching for "a_b" should only match literal underscores, not any character
      {:ok, result} = Tenants.list_tenants_admin(search: "a_b")
      names = Enum.map(result.data, & &1.tenant.name)
      assert "a_b_c Corp" in names
      refute "axbxc Corp" in names
    end

    test "returns stats via subqueries (N+1 eliminated)" do
      tenant = fixture(:tenant, %{name: "Stats Tenant"})
      fixture(:project, %{tenant_id: tenant.id})
      fixture(:project, %{tenant_id: tenant.id})
      fixture(:agent, %{tenant_id: tenant.id})

      {:ok, result} = Tenants.list_tenants_admin(search: "Stats Tenant")
      assert length(result.data) == 1

      entry = hd(result.data)
      assert entry.project_count == 2
      assert entry.agent_count == 1
      assert entry.story_count == 0
      assert entry.epic_count == 0
    end
  end

  describe "get_tenant_settings/3" do
    test "returns setting value when present" do
      tenant = fixture(:tenant, %{settings: %{"max_projects" => 10}})
      assert Tenants.get_tenant_settings(tenant, "max_projects", 50) == 10
    end

    test "returns default when setting is not present" do
      tenant = fixture(:tenant, %{settings: %{}})
      assert Tenants.get_tenant_settings(tenant, "nonexistent_key", 42) == 42
    end

    test "returns nil when no default provided and key absent" do
      tenant = fixture(:tenant, %{settings: %{}})
      assert Tenants.get_tenant_settings(tenant, "missing") == nil
    end
  end
end
