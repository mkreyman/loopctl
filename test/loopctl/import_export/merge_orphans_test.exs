defmodule Loopctl.ImportExport.MergeOrphansTest do
  @moduledoc """
  `ImportExport.merge_import_project/4`'s `:report_orphans` option (#880), pinned at the
  context: without it a merge summary carries no `stories_orphaned` key at all; with it the
  key lists the project's stories the payload did not mention, and nothing is detached.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.ImportExport

  defp seeded do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})

    {:ok, _} =
      ImportExport.import_project(tenant.id, project.id, %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Epic",
            "stories" => [
              %{"number" => "1.1", "title" => "One"},
              %{"number" => "1.2", "title" => "Two"}
            ]
          }
        ]
      })

    {tenant, project}
  end

  @partial %{
    "epics" => [
      %{"number" => 1, "title" => "Epic", "stories" => [%{"number" => "1.1", "title" => "One"}]}
    ]
  }

  test "a merge without the option carries no orphan key" do
    {tenant, project} = seeded()

    assert {:ok, summary} = ImportExport.merge_import_project(tenant.id, project.id, @partial)
    refute Map.has_key?(summary, :stories_orphaned)
  end

  test "a merge with the option lists what the payload left out, and detaches nothing" do
    {tenant, project} = seeded()

    assert {:ok, %{stories_orphaned: [%{"number" => "1.2", "title" => "Two"}]}} =
             ImportExport.merge_import_project(tenant.id, project.id, @partial,
               report_orphans: true
             )
  end
end
