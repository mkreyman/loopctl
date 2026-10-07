defmodule Loopctl.ContextRetriever.ExecutorStaleColumnTest do
  @moduledoc """
  TC-30.3.6, the stale-entity edge: a declared field whose backing column was dropped returns
  `:stale_entity`.

  ## Why `async: false`

  The test's subject is a real stale schema, so it drops `stories.sort_key` (DDL on a shared
  table, rolled back at test exit). An async test holding that lock blocks every concurrent test
  touching `stories` (`Loopctl.Test.LockGuard` refuses it). Faking the failure instead would
  only prove that a raised error is rescued, not that a dropped column reaches the caller as
  `:stale_entity`. The rest of TC-30.3.6 runs async in `executor_test.exs`.
  """

  use Loopctl.DataCase, async: false

  alias Loopctl.ContextRetriever.Executor
  alias Loopctl.ContextRetriever.Registry
  alias Loopctl.ContextRetriever.Scope
  alias Loopctl.Projects.Project
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

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

  defp seed_story(tenant_id, attrs) do
    project =
      %Project{tenant_id: tenant_id}
      |> Project.create_changeset(build(:project, %{}))
      |> Repo.insert!()

    epic =
      %Epic{tenant_id: tenant_id, project_id: project.id}
      |> Epic.create_changeset(build(:epic, %{}))
      |> Repo.insert!()

    %Story{tenant_id: tenant_id, project_id: project.id, epic_id: epic.id}
    |> Story.create_changeset(build(:story, attrs))
    |> Repo.insert!()
  end

  test "a declared field whose backing column was dropped returns :stale_entity" do
    tenant = repo_tenant()
    seed_story(tenant.id, %{title: "Some story", number: "101"})

    # sort_key is a server-allowlisted :integer column, not part of the
    # search_vector and not :decimal (so it is filter-supported). Declaring it
    # filterable, then dropping the underlying column, simulates a stale entity
    # def whose backing column no longer exists.
    {:ok, _entity} =
      Registry.create_entity(tenant.id, %{
        name: "story",
        backing_source: :stories,
        fields: [%{name: "sort_key", type: :integer, filterable: true, searchable: false}]
      })

    # Drop the backing column on the Repo connection (rolls back at test exit).
    # `Registry.create_entity/2` ran through `Repo.with_tenant`, whose
    # `SET LOCAL ROLE loopctl_app` persists for the rest of the sandbox
    # transaction; reset to the owner role so the DDL is permitted.
    Repo.query!("RESET ROLE")
    Repo.query!("ALTER TABLE stories DROP COLUMN sort_key")

    scope = %Scope{
      tenant_id: tenant.id,
      role: :agent,
      actor_id: Ecto.UUID.generate(),
      actor_label: "agent:test"
    }

    assert {:error, :stale_entity} =
             Executor.run(scope, {"story", "sort_key", :filter}, %{"sort_key" => "3"})
  end
end
