defmodule Loopctl.ContextRetriever.ExecutorTest do
  @moduledoc """
  US-30.3 — integration tests for `Loopctl.ContextRetriever.Executor.run/3`, the
  security boundary that turns a generated tool call into a safe, parameterized,
  tenant-scoped Ecto query.

  ## Why `async: false` + `Repo`-connection seeding

  The executor reads through `Loopctl.Repo.with_tenant/2` (RLS transactions with
  `SET LOCAL ROLE loopctl_app`), which needs shared sandbox mode and
  same-connection seeding. The backing rows (projects/epics/stories) and the
  tenant are therefore seeded via `Repo` (NOT the AdminRepo-backed `fixture/2`),
  so they live on the SAME DB connection the executor reads on — mirroring
  `registry_test.exs`'s `repo_tenant/0` pattern.

  Because the isolation assertions run under the NON-owner app role (RLS is ENABLE
  not FORCE), they actually prove tenant isolation rather than silently passing
  (AC-30.3.2). Audit rows are written by the executor via `AdminRepo`
  (`Audit.create_log_entry/2`) and read back via `AdminRepo` here.
  """
  use Loopctl.DataCase, async: false

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.ContextRetriever.Executor
  alias Loopctl.ContextRetriever.MockAudit
  alias Loopctl.ContextRetriever.Registry
  alias Loopctl.ContextRetriever.Scope
  alias Loopctl.Projects.Project
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

  # --- Repo-connection seeding helpers (see moduledoc) ---

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

  defp seed_project(tenant_id, attrs \\ %{}) do
    %Project{tenant_id: tenant_id}
    |> Project.create_changeset(build(:project, attrs))
    |> Repo.insert!()
  end

  defp seed_epic(tenant_id, project_id, attrs \\ %{}) do
    %Epic{tenant_id: tenant_id, project_id: project_id}
    |> Epic.create_changeset(build(:epic, attrs))
    |> Repo.insert!()
  end

  defp seed_story(tenant_id, attrs) do
    project = seed_project(tenant_id)
    epic = seed_epic(tenant_id, project.id)

    %Story{tenant_id: tenant_id, project_id: project.id, epic_id: epic.id}
    |> Story.create_changeset(build(:story, attrs))
    |> Repo.insert!()
  end

  defp create_story_entity(tenant_id, fields) do
    {:ok, entity} =
      Registry.create_entity(tenant_id, %{name: "story", backing_source: :stories, fields: fields})

    entity
  end

  defp scope_for(tenant) do
    %Scope{
      tenant_id: tenant.id,
      role: :agent,
      actor_id: Ecto.UUID.generate(),
      actor_label: "agent:test"
    }
  end

  defp context_audits(tenant_id) do
    AdminRepo.all(
      from a in AuditLog,
        where: a.tenant_id == ^tenant_id and a.entity_type == "context_retrieval"
    )
  end

  # title (filterable + searchable) + number (filterable) — enough to distinguish
  # rows across tenants in the result projection (id is not allowlisted).
  @story_fields [
    %{name: "title", type: :string, filterable: true, searchable: true},
    %{name: "number", type: :string, filterable: true, searchable: false}
  ]

  describe "TC-30.3.1 — filter: parameterized, tenant-scoped, shaped, audited" do
    test "returns only caller-tenant matching rows with meta and writes an audit row" do
      tenant_a = repo_tenant()
      tenant_b = repo_tenant()

      seed_story(tenant_a.id, %{title: "Shared Title", number: "101"})
      seed_story(tenant_a.id, %{title: "Other", number: "102"})
      # Tenant B has an IDENTICALLY-titled row that must never surface for A.
      seed_story(tenant_b.id, %{title: "Shared Title", number: "201"})

      create_story_entity(tenant_a.id, @story_fields)
      scope = scope_for(tenant_a)

      assert {:ok, %{results: results, meta: meta}} =
               Executor.run(scope, {"story", "title", :filter}, %{"title" => "Shared Title"})

      # Only tenant A's matching row, shaped to declared fields only.
      assert results == [%{title: "Shared Title", number: "101"}]
      assert meta.total_count == 1
      assert meta.limit == 5
      assert meta.offset == 0

      # Audit row captures the execution.
      assert [audit] = context_audits(tenant_a.id)
      assert audit.action == "filter"
      assert audit.actor_label == "agent:test"
      assert audit.metadata["entity"] == "story"
      assert audit.metadata["field"] == "title"
      assert audit.metadata["operation"] == "filter"
      assert audit.metadata["row_count"] == 1
      assert is_binary(audit.metadata["param_digest"])
      # Raw filter value is never stored.
      refute audit.metadata["param_digest"] =~ "Shared Title"
    end
  end

  describe "TC-30.3.2 — non-allowlisted field rejected at execute time" do
    test "a field the entity does not declare is rejected, no query run, no audit" do
      tenant = repo_tenant()
      seed_story(tenant.id, %{title: "Anything", number: "101"})
      create_story_entity(tenant.id, @story_fields)

      assert {:error, :field_not_allowlisted} =
               Executor.run(scope_for(tenant), {"story", "tenant_id", :filter}, %{
                 "tenant_id" => "x"
               })

      # Rejected before any query/audit.
      assert context_audits(tenant.id) == []
    end

    test "a declared-but-non-filterable field is rejected" do
      tenant = repo_tenant()
      seed_story(tenant.id, %{title: "Anything", number: "101"})

      # description declared searchable only (filterable: false).
      create_story_entity(tenant.id, [
        %{name: "title", type: :string, filterable: true, searchable: true},
        %{name: "description", type: :string, filterable: false, searchable: true}
      ])

      assert {:error, :field_not_allowlisted} =
               Executor.run(scope_for(tenant), {"story", "description", :filter}, %{
                 "description" => "x"
               })
    end

    test "an unknown entity is rejected" do
      tenant = repo_tenant()

      assert {:error, :unknown_entity} =
               Executor.run(scope_for(tenant), {"nope", "title", :filter}, %{"title" => "x"})
    end
  end

  describe "TC-30.3.3 — injection payloads are literals, not SQL" do
    test "a filter injection value matches nothing and raises no SQL error" do
      tenant = repo_tenant()
      seed_story(tenant.id, %{title: "Legit", number: "101"})
      create_story_entity(tenant.id, @story_fields)

      assert {:ok, %{results: [], meta: %{total_count: 0}}} =
               Executor.run(scope_for(tenant), {"story", "title", :filter}, %{
                 "title" => "' OR 1=1 --"
               })
    end

    test "a search injection query matches nothing and does not drop the table" do
      tenant = repo_tenant()
      seed_story(tenant.id, %{title: "Legit story", number: "101"})
      create_story_entity(tenant.id, @story_fields)

      assert {:ok, %{results: [], meta: %{total_count: 0}}} =
               Executor.run(scope_for(tenant), {"story", nil, :search}, %{
                 "query" => "'; DROP TABLE stories; --"
               })

      # The table still exists and is queryable — the payload was a literal.
      assert Repo.aggregate(from(s in Story), :count, :id) >= 0
    end
  end

  describe "TC-30.3.4 — full-text search via GIN-indexed tsvector" do
    test "search matches on the indexed search_vector and returns a shaped page" do
      tenant = repo_tenant()
      seed_story(tenant.id, %{title: "Photosynthesis research notes", number: "101"})
      seed_story(tenant.id, %{title: "Unrelated topic", number: "102"})
      create_story_entity(tenant.id, @story_fields)

      assert {:ok, %{results: results, meta: meta}} =
               Executor.run(scope_for(tenant), {"story", nil, :search}, %{
                 "query" => "photosynthesis"
               })

      assert results == [%{title: "Photosynthesis research notes", number: "101"}]
      assert meta.total_count == 1

      # Search is audited too.
      assert [audit] = context_audits(tenant.id)
      assert audit.action == "search"
      assert audit.metadata["operation"] == "search"
    end
  end

  describe "TC-30.3.5 — pagination cap + tenant override defense" do
    test "results are capped at the max page size; params[:tenant_id] cannot widen scope" do
      tenant_a = repo_tenant()
      tenant_b = repo_tenant()

      for i <- 1..7 do
        seed_story(tenant_a.id, %{title: "PageTest", number: "#{100 + i}"})
      end

      seed_story(tenant_b.id, %{title: "PageTest", number: "201"})

      create_story_entity(tenant_a.id, @story_fields)

      assert {:ok, %{results: results, meta: meta}} =
               Executor.run(scope_for(tenant_a), {"story", "title", :filter}, %{
                 "title" => "PageTest",
                 "limit" => 100,
                 # A malicious tenant override that must be ignored entirely.
                 "tenant_id" => tenant_b.id
               })

      # Capped at config max (5 in test.exs), not the requested 100.
      assert length(results) == 5
      assert meta.limit == 5
      # total_count counts ALL of tenant A's 7 matches — NOT tenant B's row,
      # proving the param tenant_id did not widen the scope.
      assert meta.total_count == 7

      # offset paging returns the rest, still capped and tenant-scoped.
      assert {:ok, %{results: page2, meta: meta2}} =
               Executor.run(scope_for(tenant_a), {"story", "title", :filter}, %{
                 "title" => "PageTest",
                 "limit" => 100,
                 "offset" => 5
               })

      assert length(page2) == 2
      assert meta2.offset == 5
      assert meta2.total_count == 7
    end
  end

  describe "TC-30.3.6 — fail-closed edges" do
    test "a nil-tenant (superadmin) scope is refused with no cross-tenant read" do
      superadmin_scope = %Scope{tenant_id: nil, role: :superadmin, actor_label: "superadmin"}

      assert {:error, :no_tenant} =
               Executor.run(superadmin_scope, {"story", "title", :filter}, %{"title" => "x"})
    end

    test "a declared field whose backing column was dropped returns :stale_entity" do
      tenant = repo_tenant()
      seed_story(tenant.id, %{title: "Some story", number: "101"})

      # estimated_hours is server-allowlisted and text-safe to drop (not part of
      # search_vector). Declaring it filterable, then dropping the underlying
      # column, simulates a stale entity def.
      create_story_entity(tenant.id, [
        %{name: "estimated_hours", type: :float, filterable: true, searchable: false}
      ])

      # Drop the backing column on the Repo connection (rolls back at test exit).
      # `create_story_entity/2` ran through `Repo.with_tenant`, whose
      # `SET LOCAL ROLE loopctl_app` persists for the rest of the sandbox
      # transaction; reset to the owner role so the DDL is permitted.
      Repo.query!("RESET ROLE")
      Repo.query!("ALTER TABLE stories DROP COLUMN estimated_hours")

      assert {:error, :stale_entity} =
               Executor.run(scope_for(tenant), {"story", "estimated_hours", :filter}, %{
                 "estimated_hours" => "1.5"
               })
    end
  end

  describe "TC-30.3.7 — mistyped filter value returns an empty page (no DB type error)" do
    test "a non-numeric value for an integer-declared field yields zero rows via :no_match" do
      tenant = repo_tenant()
      seed_story(tenant.id, %{title: "Has a sort key", number: "101"})

      # sort_key is an allowlisted stories column declared here as an integer.
      create_story_entity(tenant.id, [
        %{name: "sort_key", type: :integer, filterable: true, searchable: false}
      ])

      # "not-a-number" cannot represent the declared integer type -> cast_value/2
      # returns :no_match, so the executor returns an empty page WITHOUT issuing a
      # query (never a DB type error).
      assert {:ok, %{results: [], meta: meta}} =
               Executor.run(scope_for(tenant), {"story", "sort_key", :filter}, %{
                 "sort_key" => "not-a-number"
               })

      assert meta.total_count == 0

      # Still audited (row_count 0) — the value never reached the DB.
      assert [audit] = context_audits(tenant.id)
      assert audit.metadata["row_count"] == 0
    end

    test "a nil filter value yields zero rows via :no_match" do
      tenant = repo_tenant()
      seed_story(tenant.id, %{title: "Present", number: "101"})
      create_story_entity(tenant.id, @story_fields)

      # No value supplied for the declared field -> fetch_param returns nil ->
      # cast_value(nil, _) is :no_match -> empty page, no query.
      assert {:ok, %{results: [], meta: %{total_count: 0}}} =
               Executor.run(scope_for(tenant), {"story", "title", :filter}, %{})
    end
  end

  describe "AC-30.3.4 — search rejected when a declared searchable column is not vector-indexed" do
    test "a searchable column outside the source search_vector returns :search_not_indexed" do
      tenant = repo_tenant()
      seed_story(tenant.id, %{title: "Anything", number: "101"})

      # agent_status is allowlisted + declarable as a string, but is NOT covered by
      # the stories search_vector (title + description). The executor must REJECT
      # the search rather than silently match against title/description.
      create_story_entity(tenant.id, [
        %{name: "agent_status", type: :string, filterable: false, searchable: true}
      ])

      assert {:error, :search_not_indexed} =
               Executor.run(scope_for(tenant), {"story", nil, :search}, %{"query" => "anything"})

      # Rejected before any query/audit.
      assert context_audits(tenant.id) == []
    end
  end

  describe "invalid-operation branches" do
    test "search over an entity with no searchable text field returns :invalid_operation" do
      tenant = repo_tenant()
      seed_story(tenant.id, %{title: "x", number: "101"})

      # Only a non-searchable filterable field declared -> no searchable columns.
      create_story_entity(tenant.id, [
        %{name: "number", type: :string, filterable: true, searchable: false}
      ])

      assert {:error, :invalid_operation} =
               Executor.run(scope_for(tenant), {"story", nil, :search}, %{"query" => "x"})

      assert context_audits(tenant.id) == []
    end

    test "an unknown operation is rejected with :invalid_operation" do
      tenant = repo_tenant()
      create_story_entity(tenant.id, @story_fields)

      assert {:error, :invalid_operation} =
               Executor.run(scope_for(tenant), {"story", "title", :bogus_op}, %{"title" => "x"})

      assert context_audits(tenant.id) == []
    end
  end

  describe "AC-30.3.6 — audit failure fails the read closed" do
    test "when the audit write fails, run/3 returns {:error, :audit_failed} and no rows leak" do
      tenant = repo_tenant()
      seed_story(tenant.id, %{title: "Audited", number: "101"})
      create_story_entity(tenant.id, @story_fields)

      # Force the audit insert to fail for this call (overrides the DataCase default
      # stub that delegates to the real Loopctl.Audit).
      expect(MockAudit, :create_log_entry, fn _tenant_id, _attrs ->
        {:error, :db_unavailable}
      end)

      assert {:error, :audit_failed} =
               Executor.run(scope_for(tenant), {"story", "title", :filter}, %{
                 "title" => "Audited"
               })

      # No rows disclosed to the caller AND no audit row persisted — chain of
      # custody is preserved by failing closed.
      assert context_audits(tenant.id) == []
    end
  end

  describe "tenant isolation (CLAUDE.md mandatory)" do
    test "tenant A's search never returns tenant B's rows" do
      tenant_a = repo_tenant()
      tenant_b = repo_tenant()

      seed_story(tenant_a.id, %{title: "Isolation keyword alpha", number: "101"})
      seed_story(tenant_b.id, %{title: "Isolation keyword beta", number: "201"})

      create_story_entity(tenant_a.id, @story_fields)

      assert {:ok, %{results: results}} =
               Executor.run(scope_for(tenant_a), {"story", nil, :search}, %{
                 "query" => "isolation"
               })

      # Only tenant A's row, under the non-owner app role.
      assert results == [%{title: "Isolation keyword alpha", number: "101"}]
    end
  end
end
