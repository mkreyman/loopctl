defmodule Loopctl.AuditTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Audit
  alias Loopctl.Audit.AuditLog

  describe "create_log_entry/2" do
    test "creates an audit log entry" do
      tenant = fixture(:tenant)

      attrs = %{
        entity_type: "project",
        entity_id: uuid(),
        action: "created",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "user:admin",
        new_state: %{"name" => "My Project"},
        metadata: %{"source" => "api"}
      }

      assert {:ok, %AuditLog{} = entry} = Audit.create_log_entry(tenant.id, attrs)

      assert entry.tenant_id == tenant.id
      assert entry.entity_type == "project"
      assert entry.action == "created"
      assert entry.actor_type == "api_key"
      assert entry.actor_label == "user:admin"
      assert entry.new_state == %{"name" => "My Project"}
      assert entry.old_state == nil
      assert entry.metadata == %{"source" => "api"}
      assert %DateTime{} = entry.inserted_at
    end

    test "creates entry with old_state for updates" do
      tenant = fixture(:tenant)

      attrs = %{
        entity_type: "project",
        entity_id: uuid(),
        action: "updated",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "user:admin",
        old_state: %{"name" => "Old Name"},
        new_state: %{"name" => "New Name"}
      }

      assert {:ok, %AuditLog{} = entry} = Audit.create_log_entry(tenant.id, attrs)

      assert entry.old_state == %{"name" => "Old Name"}
      assert entry.new_state == %{"name" => "New Name"}
    end

    test "stores diffs not full snapshots" do
      tenant = fixture(:tenant)

      # Only changed fields are in old_state/new_state
      attrs = %{
        entity_type: "story",
        entity_id: uuid(),
        action: "updated",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "agent:worker-1",
        old_state: %{"agent_status" => "pending"},
        new_state: %{"agent_status" => "assigned"}
      }

      assert {:ok, %AuditLog{} = entry} = Audit.create_log_entry(tenant.id, attrs)

      # Verify only the changed field is stored, not full entity
      assert entry.old_state == %{"agent_status" => "pending"}
      assert entry.new_state == %{"agent_status" => "assigned"}
      refute Map.has_key?(entry.old_state, "title")
    end

    test "validates required fields" do
      tenant = fixture(:tenant)

      assert {:error, changeset} = Audit.create_log_entry(tenant.id, %{})

      errors = errors_on(changeset)
      assert errors.entity_type != []
      assert errors.entity_id != []
      assert errors.action != []
      assert errors.actor_type != []
    end

    test "sets project_id for project-scoped entries" do
      tenant = fixture(:tenant)
      project_id = uuid()

      attrs = %{
        entity_type: "story",
        entity_id: uuid(),
        action: "created",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "user:admin",
        project_id: project_id,
        new_state: %{"title" => "New Story"}
      }

      assert {:ok, %AuditLog{} = entry} = Audit.create_log_entry(tenant.id, attrs)

      assert entry.project_id == project_id
    end
  end

  describe "log_in_multi/3" do
    test "adds audit log entry to Ecto.Multi pipeline" do
      tenant = fixture(:tenant)
      entity_id = uuid()

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:dummy, fn _repo, _changes ->
          {:ok, %{id: entity_id}}
        end)
        |> Audit.log_in_multi(:audit, fn %{dummy: dummy} ->
          %{
            tenant_id: tenant.id,
            entity_type: "project",
            entity_id: dummy.id,
            action: "created",
            actor_type: "api_key",
            actor_id: uuid(),
            actor_label: "user:admin",
            new_state: %{"name" => "Test"}
          }
        end)

      assert {:ok, %{audit: %AuditLog{} = entry}} =
               Loopctl.AdminRepo.transaction(multi)

      assert entry.entity_type == "project"
      assert entry.entity_id == entity_id
      assert entry.tenant_id == tenant.id
    end
  end

  describe "append-only enforcement" do
    test "UPDATE is rejected by database trigger" do
      tenant = fixture(:tenant)

      {:ok, entry} =
        Audit.create_log_entry(tenant.id, %{
          entity_type: "project",
          entity_id: uuid(),
          action: "created",
          actor_type: "api_key",
          actor_id: uuid(),
          actor_label: "user:admin",
          new_state: %{"name" => "Test"}
        })

      # Attempt to update — should be rejected by trigger
      changeset = Ecto.Changeset.change(entry, action: "modified")

      assert_raise Postgrex.Error, ~r/UPDATE on audit_log is not allowed/, fn ->
        Loopctl.AdminRepo.update!(changeset)
      end
    end

    test "DELETE is rejected by database trigger" do
      tenant = fixture(:tenant)

      {:ok, entry} =
        Audit.create_log_entry(tenant.id, %{
          entity_type: "project",
          entity_id: uuid(),
          action: "created",
          actor_type: "api_key",
          actor_id: uuid(),
          actor_label: "user:admin",
          new_state: %{"name" => "Test"}
        })

      assert_raise Postgrex.Error, ~r/DELETE on audit_log is not allowed/, fn ->
        Loopctl.AdminRepo.delete!(entry)
      end
    end
  end

  describe "list_entries/2" do
    test "returns paginated entries for a tenant" do
      tenant = fixture(:tenant)

      # Create 25 entries
      for i <- 1..25 do
        Audit.create_log_entry(tenant.id, %{
          entity_type: "project",
          entity_id: uuid(),
          action: "created",
          actor_type: "api_key",
          actor_id: uuid(),
          actor_label: "user:admin-#{i}",
          new_state: %{"name" => "Project #{i}"}
        })
      end

      # Page 1
      {:ok, result} = Audit.list_entries(tenant.id, page: 1, page_size: 10)

      assert length(result.data) == 10
      assert result.total == 25
      assert result.page == 1
      assert result.page_size == 10

      # Page 3 (5 entries)
      {:ok, result3} = Audit.list_entries(tenant.id, page: 3, page_size: 10)
      assert length(result3.data) == 5
    end

    test "filters by entity_type" do
      tenant = fixture(:tenant)

      Audit.create_log_entry(tenant.id, %{
        entity_type: "project",
        entity_id: uuid(),
        action: "created",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "user:admin"
      })

      Audit.create_log_entry(tenant.id, %{
        entity_type: "story",
        entity_id: uuid(),
        action: "created",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "user:admin"
      })

      {:ok, result} = Audit.list_entries(tenant.id, entity_type: "project")

      assert length(result.data) == 1
      assert hd(result.data).entity_type == "project"
    end

    test "filters by action" do
      tenant = fixture(:tenant)

      Audit.create_log_entry(tenant.id, %{
        entity_type: "project",
        entity_id: uuid(),
        action: "created",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "user:admin"
      })

      Audit.create_log_entry(tenant.id, %{
        entity_type: "project",
        entity_id: uuid(),
        action: "updated",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "user:admin"
      })

      {:ok, result} = Audit.list_entries(tenant.id, action: "updated")

      assert length(result.data) == 1
      assert hd(result.data).action == "updated"
    end

    test "filters by date range" do
      tenant = fixture(:tenant)
      now = DateTime.utc_now()
      past = DateTime.add(now, -3600, :second)
      future = DateTime.add(now, 3600, :second)

      Audit.create_log_entry(tenant.id, %{
        entity_type: "project",
        entity_id: uuid(),
        action: "created",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "user:admin"
      })

      {:ok, result} = Audit.list_entries(tenant.id, from: past, to: future)
      assert length(result.data) == 1

      # Future-only range should return nothing
      {:ok, empty_result} = Audit.list_entries(tenant.id, from: future)
      assert empty_result.data == []
    end

    test "returns entries in descending order by default" do
      tenant = fixture(:tenant)

      for _ <- 1..3 do
        Audit.create_log_entry(tenant.id, %{
          entity_type: "project",
          entity_id: uuid(),
          action: "created",
          actor_type: "api_key",
          actor_id: uuid(),
          actor_label: "user:admin"
        })
      end

      {:ok, result} = Audit.list_entries(tenant.id)

      timestamps = Enum.map(result.data, & &1.inserted_at)
      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    end

    test "filters by project_id" do
      tenant = fixture(:tenant)
      project_id = uuid()

      Audit.create_log_entry(tenant.id, %{
        entity_type: "story",
        entity_id: uuid(),
        action: "created",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "user:admin",
        project_id: project_id
      })

      Audit.create_log_entry(tenant.id, %{
        entity_type: "story",
        entity_id: uuid(),
        action: "created",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "user:admin",
        project_id: uuid()
      })

      {:ok, result} = Audit.list_entries(tenant.id, project_id: project_id)

      assert length(result.data) == 1
      assert hd(result.data).project_id == project_id
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's audit entries" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      Audit.create_log_entry(tenant_a.id, %{
        entity_type: "project",
        entity_id: uuid(),
        action: "created",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "user:admin-a"
      })

      Audit.create_log_entry(tenant_b.id, %{
        entity_type: "project",
        entity_id: uuid(),
        action: "created",
        actor_type: "api_key",
        actor_id: uuid(),
        actor_label: "user:admin-b"
      })

      {:ok, result_a} = Audit.list_entries(tenant_a.id)
      {:ok, result_b} = Audit.list_entries(tenant_b.id)

      assert length(result_a.data) == 1
      assert hd(result_a.data).actor_label == "user:admin-a"

      assert length(result_b.data) == 1
      assert hd(result_b.data).actor_label == "user:admin-b"
    end
  end
end
