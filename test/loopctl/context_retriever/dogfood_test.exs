defmodule Loopctl.ContextRetriever.DogfoodTest do
  @moduledoc """
  US-30.6 — integration tests proving the dogfood entity definitions
  (`Loopctl.ContextRetriever.Dogfood`) give the generated Context-Retriever tool
  surface PARITY with (and never a broader read than) the hand-written
  `Loopctl.WorkBreakdown.Stories` oracle, expose ONLY server-allowlisted columns,
  and are tenant-isolated under the non-owner app role.

  ## Why `async: false` + `Repo`-connection seeding

  Same as `executor_test.exs`: the executor (`Executor.run/3`) reads through
  `Loopctl.Repo.with_tenant/2` (RLS transactions with `SET LOCAL ROLE
  loopctl_app`), which needs shared sandbox mode and same-connection seeding. The
  backing rows the EXECUTOR reads are therefore seeded via `Repo` (NOT the
  AdminRepo-backed `fixture/2`) so they live on the SAME DB connection the
  executor reads on. Because the isolation assertions run under the NON-owner app
  role (RLS is ENABLE not FORCE), they actually prove tenant isolation.

  ## How parity against the REAL oracle is proven (AC-30.6.2)

  The two-repo sandbox split makes a byte-identical, same-tenant comparison
  impossible: `Executor.run/3` reads via `Repo` while the oracle
  (`Stories.list_stories/3`) reads via `AdminRepo`, and those are SEPARATE
  sandbox transactions whose uncommitted rows are invisible to each other (probed
  directly). A single tenant cannot exist in both at once either — the
  `tenants` PK and the `stories.tenant_id` FK would make the second transaction's
  insert of the same tenant block on the first's uncommitted row.

  So parity is proven from ONE shared data spec (`@story_spec`) materialized on
  BOTH sides:

    * the EXECUTOR side seeds the spec via `Repo` and runs the real
      `Executor.run/3` for `agent_status: "pending"`; and
    * the ORACLE side seeds the SAME spec via `fixture/2` (AdminRepo) under a
      separate tenant and runs the real `Stories.list_stories/3` union across its
      epics for `agent_status: :pending`.

  Both are asserted to yield the SAME `@expected_pending` title set, and the
  generated set is asserted `⊆` the oracle union (never broader) AND `==` it
  (exact, since stories have no soft-delete/hidden rows — a story is "hidden" only
  by tenant scope or a non-matching status, both exercised here).

  ## Identity key for parity: `title`, not `id`

  The generated result rows are shaped to the entity's DECLARED (allowlisted)
  columns only — and `id` is deliberately NOT allowlisted (AC-30.6.3). So parity
  compares the SET of unique story `title`s (a declared, per-row-unique column)
  standing in for identity: if the generated path exposed a story the oracle
  hides, its title would appear generated-side but not oracle-side.
  """
  use Loopctl.DataCase, async: false

  setup :verify_on_exit!

  alias Loopctl.Audit.AuditLog
  alias Loopctl.ContextRetriever.Dogfood
  alias Loopctl.ContextRetriever.Entity
  alias Loopctl.ContextRetriever.Executor
  alias Loopctl.ContextRetriever.Registry
  alias Loopctl.ContextRetriever.Scope
  alias Loopctl.Projects.Project
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.WorkBreakdown.Story

  # Shared story spec: {title, agent_status, epic_key}. Materialized on BOTH the
  # executor (Repo) and oracle (AdminRepo/fixtures) sides so the two independent
  # query paths are compared over the SAME logical dataset (see moduledoc).
  @story_spec [
    {"Alpha pending", :pending, :e1},
    {"Bravo pending", :pending, :e1},
    {"Delta pending", :pending, :e2},
    {"Charlie implementing", :implementing, :e1},
    {"Echo reported_done", :reported_done, :e2}
  ]
  @expected_pending MapSet.new(["Alpha pending", "Bravo pending", "Delta pending"])

  # --- Repo-connection seeding helpers (executor side; see moduledoc) ---

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
    {status, attrs} = Map.pop(Enum.into(attrs, %{}), :status, :active)

    %Project{tenant_id: tenant_id, status: status}
    |> Project.create_changeset(build(:project, attrs))
    |> Repo.insert!()
  end

  defp seed_epic(tenant_id, project_id, attrs \\ %{}) do
    %Epic{tenant_id: tenant_id, project_id: project_id}
    |> Epic.create_changeset(build(:epic, attrs))
    |> Repo.insert!()
  end

  # agent_status is NOT cast by Story.create_changeset (it is managed via status
  # endpoints), so set it programmatically on the struct to seed varied statuses.
  defp seed_story(tenant_id, project_id, epic_id, attrs) do
    {agent_status, attrs} = Map.pop(Enum.into(attrs, %{}), :agent_status, :pending)

    %Story{
      tenant_id: tenant_id,
      project_id: project_id,
      epic_id: epic_id,
      agent_status: agent_status
    }
    |> Story.create_changeset(build(:story, attrs))
    |> Repo.insert!()
  end

  # Materialize @story_spec on the EXECUTOR side (Repo). Returns the two epics.
  defp materialize_repo(tenant_id, spec) do
    project = seed_project(tenant_id)
    epics = %{e1: seed_epic(tenant_id, project.id), e2: seed_epic(tenant_id, project.id)}

    Enum.each(spec, fn {title, status, epic_key} ->
      seed_story(tenant_id, project.id, epics[epic_key].id, %{title: title, agent_status: status})
    end)

    epics
  end

  # Materialize @story_spec on the ORACLE side (AdminRepo via fixtures). Returns
  # the two epics so the oracle union can iterate them. `fixture(:story)` honors
  # the `:agent_status` override.
  defp materialize_admin(tenant_id, spec) do
    project = fixture(:project, tenant_id: tenant_id)

    epics = %{
      e1: fixture(:epic, tenant_id: tenant_id, project_id: project.id),
      e2: fixture(:epic, tenant_id: tenant_id, project_id: project.id)
    }

    Enum.each(spec, fn {title, status, epic_key} ->
      fixture(:story,
        tenant_id: tenant_id,
        project_id: project.id,
        epic_id: epics[epic_key].id,
        title: title,
        agent_status: status
      )
    end)

    Map.values(epics)
  end

  defp scope_for(tenant_id) do
    %Scope{
      tenant_id: tenant_id,
      role: :agent,
      actor_id: Ecto.UUID.generate(),
      actor_label: "agent:test"
    }
  end

  defp titles(rows), do: rows |> Enum.map(& &1.title) |> MapSet.new()

  # Union of the REAL oracle's stories across the tenant's epics for a status.
  defp oracle_story_titles(tenant_id, epics, agent_status) do
    epics
    |> Enum.flat_map(fn epic ->
      {:ok, %{data: data}} = Stories.list_stories(tenant_id, epic.id, agent_status: agent_status)
      data
    end)
    |> titles()
  end

  describe "seed_default_entities/2" do
    test "creates the three dogfood entities via the vetted registry path (allowlist + audit)" do
      tenant = repo_tenant()

      assert {:ok, %{projects: project_entity, stories: story_entity, epics: epic_entity}} =
               Dogfood.seed_default_entities(tenant.id)

      assert project_entity.name == "project"
      assert project_entity.backing_source == :projects
      assert story_entity.name == "story"
      assert story_entity.backing_source == :stories
      assert epic_entity.name == "epic"
      assert epic_entity.backing_source == :epics

      # Only allowlisted columns were declarable — the create path would reject
      # anything else. Spot-check the story declares agent_status.
      declared = MapSet.new(story_entity.fields, &Entity.field_string_value(&1, "name"))
      assert MapSet.member?(declared, "agent_status")
    end

    test "is idempotent — re-seeding returns the existing entities, no cap burn or error" do
      tenant = repo_tenant()

      assert {:ok, first} = Dogfood.seed_default_entities(tenant.id)
      assert {:ok, second} = Dogfood.seed_default_entities(tenant.id)

      assert first.stories.id == second.stories.id
      assert first.projects.id == second.projects.id
      assert first.epics.id == second.epics.id
    end

    test "an unchanged definition is not spuriously updated on re-seed" do
      tenant = repo_tenant()

      assert {:ok, first} = Dogfood.seed_default_entities(tenant.id)
      assert {:ok, second} = Dogfood.seed_default_entities(tenant.id)

      # No reconciliation fired for an already-canonical row: same id AND same
      # updated_at (an in-place update would bump the timestamp).
      assert first.projects.id == second.projects.id
      assert first.projects.updated_at == second.projects.updated_at

      # And no "updated" audit entry was written — only the original "created".
      {:ok, actions} =
        Repo.with_tenant(tenant.id, fn ->
          Repo.all(
            from(a in AuditLog,
              where: a.entity_type == "entity_definition" and a.entity_id == ^first.projects.id,
              select: a.action
            )
          )
        end)

      assert actions == ["created"]
    end

    test "reconciles a drifted definition in place (id preserved, canonical fields restored)" do
      tenant = repo_tenant()

      assert {:ok, first} = Dogfood.seed_default_entities(tenant.id)
      project_id = first.projects.id

      # Drift: shrink the persisted `project` definition to a single allowlisted
      # field via the vetted PATCH path (simulates an out-of-band edit or a
      # definition-set change that a plain idempotent re-seed would ignore).
      assert {:ok, drifted} =
               Registry.update_entity(tenant.id, project_id, %{
                 fields: [%{name: "status", type: "string", filterable: true, searchable: false}]
               })

      assert length(drifted.fields) == 1

      # Re-seed reconciles the drift back to the canonical 4-field shape, in place.
      assert {:ok, second} = Dogfood.seed_default_entities(tenant.id)
      assert second.projects.id == project_id

      restored = MapSet.new(second.projects.fields, &Entity.field_string_value(&1, "name"))
      assert restored == MapSet.new(["status", "name", "description", "mission"])

      # The reconciliation is audited as an in-place update (security-root change).
      {:ok, actions} =
        Repo.with_tenant(tenant.id, fn ->
          Repo.all(
            from(a in AuditLog,
              where: a.entity_type == "entity_definition" and a.entity_id == ^project_id,
              select: a.action,
              order_by: a.inserted_at
            )
          )
        end)

      assert "updated" in actions
    end

    test "near the entity cap, seeding is all-or-nothing (no partial committed set)" do
      # config/test.exs caps entities at 3 — exactly the dogfood count. Pre-seed
      # one UNRELATED entity so creating all three dogfood definitions would exceed
      # the cap; the pre-flight headroom check must reject up front, committing none.
      tenant = repo_tenant()

      assert {:ok, _extra} =
               Registry.create_entity(tenant.id, %{
                 name: "extra",
                 backing_source: :projects,
                 fields: [%{name: "status", type: "string", filterable: true, searchable: false}]
               })

      assert {:error, {"project", :entity_limit}} = Dogfood.seed_default_entities(tenant.id)

      # No partial set landed — only the pre-seeded "extra" exists.
      names = tenant.id |> Registry.for_tenant() |> Enum.map(& &1.name) |> MapSet.new()
      assert names == MapSet.new(["extra"])
    end

    test "forwards actor_type to the audit trail (mix task attributes as \"system\")" do
      tenant = repo_tenant()

      assert {:ok, %{projects: project}} =
               Dogfood.seed_default_entities(tenant.id,
                 actor_type: "system",
                 actor_label: "mix loopctl.seed_context_entities"
               )

      {:ok, [audit]} =
        Repo.with_tenant(tenant.id, fn ->
          Repo.all(
            from(a in AuditLog,
              where: a.entity_type == "entity_definition" and a.entity_id == ^project.id
            )
          )
        end)

      assert audit.actor_type == "system"
      assert audit.actor_label == "mix loopctl.seed_context_entities"
    end
  end

  describe "TC-30.6.1 — generated story filter is not a broader read than list_stories" do
    test "cr_filter_story_by_agent_status ⊆ (and ==) the list_stories oracle union; scope holds" do
      # EXECUTOR side (Repo): seed the shared spec + an OTHER tenant's pending
      # story that must never leak.
      exec_tenant = repo_tenant()
      materialize_repo(exec_tenant.id, @story_spec)

      other_tenant = repo_tenant()

      other_project = seed_project(other_tenant.id)
      other_epic = seed_epic(other_tenant.id, other_project.id)

      seed_story(other_tenant.id, other_project.id, other_epic.id, %{
        title: "Foreign pending",
        agent_status: :pending
      })

      {:ok, _} = Dogfood.seed_default_entities(exec_tenant.id)

      assert {:ok, %{results: results, meta: meta}} =
               Executor.run(scope_for(exec_tenant.id), {"story", "agent_status", :filter}, %{
                 "agent_status" => "pending"
               })

      generated = titles(results)

      # ORACLE side (AdminRepo): the REAL Stories.list_stories over an equivalent
      # dataset (same @story_spec) under a separate tenant.
      oracle_tenant = fixture(:tenant)
      oracle_epics = materialize_admin(oracle_tenant.id, @story_spec)
      oracle = oracle_story_titles(oracle_tenant.id, oracle_epics, :pending)

      # The real oracle yields exactly the pending set from the shared spec.
      assert oracle == @expected_pending

      # SUBSET: the generated surface exposes NO story the oracle union hides
      # (the core "never a broader read" guarantee) — AND is exactly equal, since
      # stories have no soft-delete/hidden rows.
      assert MapSet.subset?(generated, oracle)
      assert generated == oracle
      assert generated == @expected_pending

      # total_count counts ALL of the tenant's pending stories across epics,
      # matching the oracle union size — not truncated, not broader.
      assert meta.total_count == MapSet.size(oracle)
      assert meta.total_count == 3

      # Hidden rows are absent: other-status and other-tenant never leak.
      refute MapSet.member?(generated, "Charlie implementing")
      refute MapSet.member?(generated, "Echo reported_done")
      refute MapSet.member?(generated, "Foreign pending")
    end
  end

  describe "TC-30.6.2 — no undeclared column leaks" do
    test "generated story rows contain ONLY the declared allowlisted fields" do
      tenant = repo_tenant()
      project = seed_project(tenant.id)
      epic = seed_epic(tenant.id, project.id)
      seed_story(tenant.id, project.id, epic.id, %{title: "Leak check", agent_status: :pending})

      {:ok, _} = Dogfood.seed_default_entities(tenant.id)

      assert {:ok, %{results: [row]}} =
               Executor.run(scope_for(tenant.id), {"story", "agent_status", :filter}, %{
                 "agent_status" => "pending"
               })

      # Exactly the declared story fields — no id, no tenant_id, no custody/audit
      # columns (Executor's whitelist `select map(q, ^select_cols)`).
      assert MapSet.new(Map.keys(row)) ==
               MapSet.new([:agent_status, :verified_status, :epic_id, :title, :description])

      refute Map.has_key?(row, :id)
      refute Map.has_key?(row, :tenant_id)
      refute Map.has_key?(row, :metadata)
      refute Map.has_key?(row, :project_id)
      refute Map.has_key?(row, :implementer_dispatch_id)
      refute Map.has_key?(row, :verifier_dispatch_id)
      refute Map.has_key?(row, :assigned_agent_id)
      refute Map.has_key?(row, :assigned_at)
      refute Map.has_key?(row, :sort_key)
    end
  end

  describe "TC-30.6.3 — generated story query is tenant-isolated (parity)" do
    test "an agent of tenant A never sees tenant B's stories, under the app role" do
      tenant_a = repo_tenant()
      tenant_b = repo_tenant()

      project_a = seed_project(tenant_a.id)
      epic_a = seed_epic(tenant_a.id, project_a.id)
      seed_story(tenant_a.id, project_a.id, epic_a.id, %{title: "A-only", agent_status: :pending})

      project_b = seed_project(tenant_b.id)
      epic_b = seed_epic(tenant_b.id, project_b.id)
      seed_story(tenant_b.id, project_b.id, epic_b.id, %{title: "B-only", agent_status: :pending})

      # Both tenants declare the same dogfood entity — isolation is enforced by
      # the executor's tenant scope, not by the entity being absent for B.
      {:ok, _} = Dogfood.seed_default_entities(tenant_a.id)
      {:ok, _} = Dogfood.seed_default_entities(tenant_b.id)

      assert {:ok, %{results: results}} =
               Executor.run(scope_for(tenant_a.id), {"story", "agent_status", :filter}, %{
                 "agent_status" => "pending"
               })

      generated = titles(results)
      assert MapSet.member?(generated, "A-only")
      refute MapSet.member?(generated, "B-only")
    end
  end

  describe "AC-30.6.1 smoke — projects/epics dogfood entities work end to end" do
    test "cr_filter_project_by_status returns active projects only, shaped to declared columns" do
      tenant = repo_tenant()

      active1 = seed_project(tenant.id, %{name: "Active One", status: :active})
      active2 = seed_project(tenant.id, %{name: "Active Two", status: :active})
      _archived = seed_project(tenant.id, %{name: "Archived One", status: :archived})

      {:ok, _} = Dogfood.seed_default_entities(tenant.id)

      assert {:ok, %{results: results}} =
               Executor.run(scope_for(tenant.id), {"project", "status", :filter}, %{
                 "status" => "active"
               })

      generated = results |> Enum.map(& &1.name) |> MapSet.new()

      # Parity with the vetted Projects.list_projects semantics: an active-status
      # filter returns exactly the active projects and hides archived ones. (The
      # real list_projects reads via AdminRepo — a separate sandbox transaction —
      # so the direct executor assertion below stands in for it over the Repo-side
      # rows the executor actually reads; the story-level parity test above anchors
      # the comparison to a real hand-written oracle.)
      assert generated == MapSet.new([active1.name, active2.name])
      refute MapSet.member?(generated, "Archived One")

      # Declared project columns only.
      [row | _] = results
      assert MapSet.new(Map.keys(row)) == MapSet.new([:status, :name, :description, :mission])
    end

    test "cr_filter_epic_by_phase returns the tenant's epics for the given phase" do
      tenant = repo_tenant()
      project = seed_project(tenant.id)
      matching = seed_epic(tenant.id, project.id, %{title: "Phase match", phase: "p1_core"})
      _other = seed_epic(tenant.id, project.id, %{title: "Phase miss", phase: "p0_foundation"})

      {:ok, _} = Dogfood.seed_default_entities(tenant.id)

      assert {:ok, %{results: results}} =
               Executor.run(scope_for(tenant.id), {"epic", "phase", :filter}, %{
                 "phase" => "p1_core"
               })

      result_titles = results |> Enum.map(& &1.title) |> MapSet.new()
      assert result_titles == MapSet.new([matching.title])
      assert MapSet.new(Map.keys(hd(results))) == MapSet.new([:phase, :title, :description])
    end
  end

  describe "AC-30.6.1 smoke — generated story SEARCH tool works on loopctl's own rows" do
    # The dogfood `story` entity declares `title`/`description` as searchable
    # (dogfood.ex), both of which the stories `search_vector` covers
    # (`Entity.search_vector_columns/0`), so the generated `cr_search_story` tool
    # is authorized. The filter-focused tests above never dispatch `:search`, so
    # this exercises the searchable HALF of AC-30.6.1 end to end over loopctl's
    # own rows: a `{"story", nil, :search}` call runs the GIN-indexed tsvector
    # query and shapes results to the SAME declared columns as the filter tool.
    test "cr_search_story matches on the indexed search_vector, shaped to declared columns" do
      tenant = repo_tenant()
      project = seed_project(tenant.id)
      epic = seed_epic(tenant.id, project.id)

      seed_story(tenant.id, project.id, epic.id, %{
        title: "Photosynthesis pipeline groundwork",
        agent_status: :pending
      })

      seed_story(tenant.id, project.id, epic.id, %{
        title: "Unrelated ledger topic",
        agent_status: :pending
      })

      {:ok, _} = Dogfood.seed_default_entities(tenant.id)

      assert {:ok, %{results: results, meta: meta}} =
               Executor.run(scope_for(tenant.id), {"story", nil, :search}, %{
                 "query" => "photosynthesis"
               })

      generated = titles(results)
      assert MapSet.member?(generated, "Photosynthesis pipeline groundwork")
      refute MapSet.member?(generated, "Unrelated ledger topic")
      assert meta.total_count == 1

      # Search results are shaped to the SAME declared story columns as the filter
      # tool — no id/tenant_id/custody columns leak through the search path either.
      [row | _] = results

      assert MapSet.new(Map.keys(row)) ==
               MapSet.new([:agent_status, :verified_status, :epic_id, :title, :description])
    end
  end
end
