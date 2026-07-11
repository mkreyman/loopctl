defmodule Loopctl.ContextRetriever.RegistryTest do
  # async: false — the Registry reads/writes through `Loopctl.Repo.with_tenant`
  # (RLS-enforced Repo transactions with `SET LOCAL ROLE loopctl_app`), which
  # needs shared sandbox mode and same-connection seeding (see `repo_tenant/0`).
  # This mirrors the documented RLS exception in `default_archival_test.exs` and
  # `rls_test.exs`. Because the isolation assertion runs under the NON-owner app
  # role (not a superuser/owner connection that would bypass ENABLE-only RLS), it
  # actually proves tenant isolation rather than silently passing (AC-30.1.4).
  use Loopctl.DataCase, async: false

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.Audit.AuditLog
  alias Loopctl.ContextRetriever.Entity
  alias Loopctl.ContextRetriever.Registry
  alias Loopctl.Tenants.Tenant

  @valid_fields [%{name: "title", type: :string, filterable: true, searchable: true}]

  # Seed the tenant via `Repo` (not the AdminRepo-backed `fixture(:tenant)`) so it
  # lives on the SAME DB connection as the `Repo.with_tenant` transactions the
  # Registry runs — otherwise the `entity_definitions.tenant_id` FK cannot see it.
  # This mirrors `default_archival_test.exs`'s RLS-test seeding pattern.
  defp repo_tenant do
    seq = System.unique_integer([:positive])

    %Tenant{}
    |> Tenant.create_changeset(%{
      name: "Test Tenant #{seq}",
      slug: "test-tenant-#{seq}",
      email: "test-#{seq}@example.com",
      status: :active
    })
    |> Repo.insert!()
  end

  describe "create_entity/2 + get_entity/2" do
    test "creates a definition and reads it back within the tenant" do
      tenant = repo_tenant()

      assert {:ok, %Entity{} = entity} =
               Registry.create_entity(tenant.id, %{
                 name: "story",
                 backing_source: :stories,
                 fields: @valid_fields
               })

      assert entity.tenant_id == tenant.id
      assert entity.name == "story"
      assert entity.backing_source == :stories

      fetched = Registry.get_entity(tenant.id, "story")
      assert fetched.id == entity.id
      # Round-trips through jsonb as string-keyed maps with string values.
      assert [field] = fetched.fields
      assert field["name"] == "title"
      assert field["type"] == "string"
      assert field["filterable"] == true
      assert field["searchable"] == true
    end

    test "the entity name is admin-chosen and independent of backing_source" do
      tenant = repo_tenant()

      assert {:ok, entity} =
               Registry.create_entity(tenant.id, %{
                 name: "story",
                 backing_source: :projects,
                 fields: [%{name: "name", type: :string, filterable: true, searchable: true}]
               })

      assert entity.name == "story"
      assert entity.backing_source == :projects
    end

    test "enforces unique name per tenant" do
      tenant = repo_tenant()

      assert {:ok, _} =
               Registry.create_entity(tenant.id, %{
                 name: "story",
                 backing_source: :stories,
                 fields: @valid_fields
               })

      assert {:error, changeset} =
               Registry.create_entity(tenant.id, %{
                 name: "story",
                 backing_source: :epics,
                 fields: [%{name: "title", type: :string, filterable: true, searchable: true}]
               })

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :name)
    end

    test "rejects an invalid definition via the changeset" do
      tenant = repo_tenant()

      assert {:error, changeset} =
               Registry.create_entity(tenant.id, %{
                 name: "story",
                 backing_source: :stories,
                 fields: [
                   %{name: "tenant_id", type: :string, filterable: true, searchable: false}
                 ]
               })

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :fields)
    end

    test "get_entity/2 returns nil for an unknown name" do
      tenant = repo_tenant()
      assert Registry.get_entity(tenant.id, "nope") == nil
    end

    test "writes an audit_log entry recording the security-root creation" do
      tenant = repo_tenant()
      actor_id = Ecto.UUID.generate()

      assert {:ok, entity} =
               Registry.create_entity(
                 tenant.id,
                 %{name: "story", backing_source: :stories, fields: @valid_fields},
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      # Read the audit row back through the SAME RLS Repo the Registry writes on
      # (the AdminRepo runs on a separate sandbox connection and cannot see the
      # row). RLS scopes the read to this tenant.
      {:ok, [audit]} =
        Repo.with_tenant(tenant.id, fn ->
          Repo.all(from a in AuditLog, where: a.entity_type == "entity_definition")
        end)

      assert audit.entity_id == entity.id
      assert audit.action == "created"
      assert audit.actor_id == actor_id
      assert audit.actor_label == "user:admin"
      assert audit.new_state["name"] == "story"
      assert audit.new_state["backing_source"] == "stories"
    end

    test "an invalid audit step returns {:error, _} rather than raising" do
      # A non-map `:metadata` opt fails the audit changeset's `:map` cast, so the
      # `:audit` Multi step returns `{:error, :audit, changeset, _}`. That must map
      # to the documented `{:error, _}` contract (via the catch-all clause), NOT a
      # CaseClauseError, and the transaction must roll back the entity insert.
      tenant = repo_tenant()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Registry.create_entity(
                 tenant.id,
                 %{name: "story", backing_source: :stories, fields: @valid_fields},
                 metadata: "not-a-map"
               )

      refute changeset.valid?
      # Nothing persisted — the whole transaction rolled back.
      assert Registry.for_tenant(tenant.id) == []
    end
  end

  describe "for_tenant/1 — tenant isolation (AC-30.1.3)" do
    test "a definition from tenant A is invisible to tenant B" do
      tenant_a = repo_tenant()
      tenant_b = repo_tenant()

      assert {:ok, entity_a} =
               Registry.create_entity(tenant_a.id, %{
                 name: "story",
                 backing_source: :stories,
                 fields: @valid_fields
               })

      # Tenant A sees exactly its one definition.
      assert [seen] = Registry.for_tenant(tenant_a.id)
      assert seen.id == entity_a.id

      # Tenant B sees none of tenant A's definitions (RLS under the app role).
      assert Registry.for_tenant(tenant_b.id) == []
      assert Registry.get_entity(tenant_b.id, "story") == nil
    end

    test "returns definitions ordered by name" do
      tenant = repo_tenant()

      for name <- ["zeta", "alpha", "mid"] do
        {:ok, _} =
          Registry.create_entity(tenant.id, %{
            name: name,
            backing_source: :stories,
            fields: @valid_fields
          })
      end

      assert Registry.for_tenant(tenant.id) |> Enum.map(& &1.name) == ["alpha", "mid", "zeta"]
    end
  end

  describe "tool_specs/1 — per-tenant tool-spec fan-out (US-30.4/US-30.5 entry point)" do
    test "fans ToolGenerator over all of the tenant's definitions" do
      tenant = repo_tenant()

      {:ok, _} =
        Registry.create_entity(tenant.id, %{
          name: "story",
          backing_source: :stories,
          fields: [%{name: "title", type: :string, filterable: true, searchable: false}]
        })

      {:ok, _} =
        Registry.create_entity(tenant.id, %{
          name: "project",
          backing_source: :projects,
          fields: [%{name: "status", type: :string, filterable: true, searchable: false}]
        })

      names = tenant.id |> Registry.tool_specs() |> Enum.map(& &1.name)
      assert "cr_filter_story_by_title" in names
      assert "cr_filter_project_by_status" in names
    end

    test "is []-scoped to the caller tenant (no cross-tenant specs)" do
      tenant_a = repo_tenant()
      tenant_b = repo_tenant()

      {:ok, _} =
        Registry.create_entity(tenant_a.id, %{
          name: "story",
          backing_source: :stories,
          fields: @valid_fields
        })

      assert Registry.tool_specs(tenant_b.id) == []
    end
  end

  describe "create_entity/2 — per-tenant cap (AC-30.1.5)" do
    test "over-cap creation returns {:error, :entity_limit} and inserts no row" do
      # config/test.exs sets :max_entity_definitions_per_tenant to 3.
      cap = Registry.max_entities()
      tenant = repo_tenant()

      for i <- 1..cap do
        assert {:ok, _} =
                 Registry.create_entity(tenant.id, %{
                   name: "entity_#{i}",
                   backing_source: :stories,
                   fields: @valid_fields
                 })
      end

      assert {:error, :entity_limit} =
               Registry.create_entity(tenant.id, %{
                 name: "one_too_many",
                 backing_source: :stories,
                 fields: @valid_fields
               })

      # No row was inserted for the over-cap create.
      names = Registry.for_tenant(tenant.id) |> Enum.map(& &1.name)
      assert length(names) == cap
      refute "one_too_many" in names
    end

    test "the cap is per-tenant, not global" do
      cap = Registry.max_entities()
      tenant_a = repo_tenant()
      tenant_b = repo_tenant()

      for i <- 1..cap do
        {:ok, _} =
          Registry.create_entity(tenant_a.id, %{
            name: "a_#{i}",
            backing_source: :stories,
            fields: @valid_fields
          })
      end

      # Tenant B still has full headroom despite tenant A being at cap.
      assert {:ok, _} =
               Registry.create_entity(tenant_b.id, %{
                 name: "b_1",
                 backing_source: :stories,
                 fields: @valid_fields
               })
    end
  end

  describe "update_entity/4 — allowlist re-validation + clean not-found" do
    test "a backing_source-only PATCH re-validates retained fields and does NOT persist an allowlist violation" do
      tenant = repo_tenant()

      {:ok, entity} =
        Registry.create_entity(tenant.id, %{
          name: "proj",
          backing_source: :projects,
          fields: [%{name: "mission", type: :string, filterable: true, searchable: false}]
        })

      # `mission` is a projects-only column; flipping to :stories must be rejected
      # (it is NOT in the stories allowlist), and nothing may be persisted.
      assert {:error, %Ecto.Changeset{} = cs} =
               Registry.update_entity(tenant.id, entity.id, %{"backing_source" => "stories"})

      assert Enum.any?(errors_on(cs).fields, &(&1 =~ "not an allowed column"))

      # The stored row is unchanged: still :projects with `mission`.
      reloaded = Registry.get_entity(tenant.id, "proj")
      assert reloaded.backing_source == :projects
      assert [%{"name" => "mission"}] = reloaded.fields
    end

    test "returns :not_found for an unknown id (clean 404, not a raise)" do
      tenant = repo_tenant()

      assert {:error, :not_found} =
               Registry.update_entity(tenant.id, Ecto.UUID.generate(), %{"name" => "renamed"})
    end
  end

  describe "delete_entity/3 — clean not-found" do
    test "deletes an existing entity" do
      tenant = repo_tenant()

      {:ok, entity} =
        Registry.create_entity(tenant.id, %{
          name: "story",
          backing_source: :stories,
          fields: @valid_fields
        })

      assert {:ok, deleted} = Registry.delete_entity(tenant.id, entity.id)
      assert deleted.id == entity.id
      assert Registry.get_entity(tenant.id, "story") == nil
    end

    test "returns :not_found for an unknown id (clean 404, not a raise)" do
      tenant = repo_tenant()

      assert {:error, :not_found} =
               Registry.delete_entity(tenant.id, Ecto.UUID.generate())
    end
  end
end
