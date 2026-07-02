defmodule Loopctl.TenantsTest do
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  setup :verify_on_exit!

  alias Loopctl.Secrets
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

    # rls-03: duplicate email on create must also yield a changeset error
    # (422), never a raised Ecto.ConstraintError (500).
    test "rejects duplicate email" do
      fixture(:tenant, %{email: "dupe@example.com"})

      attrs = %{name: "Other Corp", slug: "other-corp", email: "dupe@example.com"}
      assert {:error, changeset} = Tenants.create_tenant(attrs)
      assert "has already been taken" in errors_on(changeset).email
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

    # rls-02: the slug keys the audit-key Fly secret name. Renaming it would
    # strand the secret (signing hard-fails after the cache TTL), so slug must
    # be immutable on the update path.
    test "ignores attempts to change slug (immutable — rls-02)" do
      tenant = fixture(:tenant, %{slug: "original-slug"})

      assert {:ok, updated} =
               Tenants.update_tenant(tenant, %{slug: "renamed-slug", name: "New Name"})

      # The unrelated field change lands; the slug does not.
      assert updated.name == "New Name"
      assert updated.slug == "original-slug"

      # Custody link: the derived audit-key secret name is unchanged, so the
      # tenant's audit key remains resolvable after an unrelated update.
      assert Secrets.audit_key_secret_name(updated.slug) ==
               Secrets.audit_key_secret_name(tenant.slug)
    end

    test "update_changeset does not cast :slug (immutable — rls-02)" do
      tenant = fixture(:tenant, %{slug: "keep-me"})
      changeset = Tenant.update_changeset(tenant, %{slug: "changed", name: "New"})

      refute Map.has_key?(changeset.changes, :slug)
      assert changeset.changes[:name] == "New"
    end

    # rls-02: an attempted (and ignored) slug rename must leave a forensic
    # trail — it's the exact probe that would strand the audit-signing secret.
    test "logs a warning on an attempted slug mutation (rls-02 observability)" do
      tenant = fixture(:tenant, %{slug: "original-slug"})

      log =
        capture_log(fn ->
          assert {:ok, updated} =
                   Tenants.update_tenant(tenant, %{slug: "renamed-slug", name: "New Name"})

          assert updated.slug == "original-slug"
        end)

      assert log =~ "attempted slug mutation ignored for tenant #{tenant.id}"
    end

    test "does not log when slug is unchanged or absent (rls-02 observability)" do
      tenant = fixture(:tenant, %{slug: "steady-slug"})

      # slug absent
      log_absent = capture_log(fn -> Tenants.update_tenant(tenant, %{name: "Renamed"}) end)
      refute log_absent =~ "attempted slug mutation"

      # slug present but identical
      log_same =
        capture_log(fn ->
          Tenants.update_tenant(tenant, %{slug: "steady-slug", name: "Renamed Again"})
        end)

      refute log_same =~ "attempted slug mutation"
    end

    # rls-03: a colliding email must produce a clean changeset error, not a
    # raised Ecto.ConstraintError (which would surface as a 500 and act as a
    # cross-tenant email-enumeration oracle).
    test "returns changeset error on duplicate email instead of raising (rls-03)" do
      _other = fixture(:tenant, %{email: "taken@example.com"})
      tenant = fixture(:tenant, %{email: "mine@example.com"})

      assert {:error, changeset} =
               Tenants.update_tenant(tenant, %{email: "taken@example.com"})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "allows updating to a unique email (rls-03)" do
      tenant = fixture(:tenant, %{email: "mine@example.com"})

      assert {:ok, updated} =
               Tenants.update_tenant(tenant, %{email: "fresh@example.com"})

      assert updated.email == "fresh@example.com"
    end

    # Tenant isolation: tenant B cannot claim tenant A's email, and the
    # rejection leaks nothing about A beyond the standard uniqueness message.
    test "tenant cannot take another tenant's email (isolation — rls-03)" do
      tenant_a = fixture(:tenant, %{email: "a@example.com", name: "Tenant A"})
      tenant_b = fixture(:tenant, %{email: "b@example.com"})

      assert {:error, changeset} =
               Tenants.update_tenant(tenant_b, %{email: "a@example.com"})

      assert errors_on(changeset) == %{email: ["has already been taken"]}

      # Tenant A is untouched.
      assert {:ok, reloaded_a} = Tenants.get_tenant(tenant_a.id)
      assert reloaded_a.email == "a@example.com"
      assert reloaded_a.name == "Tenant A"
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
