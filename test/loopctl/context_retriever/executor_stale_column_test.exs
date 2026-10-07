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

  import ExUnit.CaptureLog
  import Loopctl.ContextRetrieverE2EHelpers, only: [seed_story: 2]

  alias Loopctl.ContextRetriever.Executor
  alias Loopctl.ContextRetriever.Registry
  alias Loopctl.ContextRetriever.Scope
  alias Loopctl.Tenants.Tenant

  setup :verify_on_exit!

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
    Repo.query!("ALTER TABLE stories DROP COLUMN sort_key")

    scope = %Scope{
      tenant_id: tenant.id,
      role: :agent,
      actor_id: Ecto.UUID.generate(),
      actor_label: "agent:test"
    }

    # The executor maps EVERY Postgrex error to :stale_entity, so the result alone cannot tell
    # the dropped column from any other failure; the logged code can.
    log =
      capture_log(fn ->
        assert {:error, :stale_entity} =
                 Executor.run(scope, {"story", "sort_key", :filter}, %{"sort_key" => "3"})
      end)

    assert log =~ ":undefined_column"
  end
end
