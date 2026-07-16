defmodule Loopctl.KnowledgeProjectScopeTest do
  @moduledoc """
  #411 Gap 2 (PR B): the `:project_scope` option on `search_combined/3`.

  `:strict` (the DEFAULT) keeps the historical project-only filter for every existing
  caller; `:with_global` switches to the merged `global ∪ project` predicate the merged
  `Loopctl.Memory.recall_context/2` recall needs. These tests pin BOTH: that a default
  strict combined search still returns project-only (regression guard) and that
  `:with_global` additionally surfaces tenant-wide (global) articles — while a DIFFERENT
  project's articles are excluded under either mode.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  # Same-direction vectors → cosine distance 0 (all match semantically), so the project
  # filter is the only thing separating the result sets.
  defp query_vector, do: List.duplicate(1.0, 768) ++ List.duplicate(0.0, 768)

  defp article(tenant_id, project_id, title) do
    article =
      fixture(:article, %{
        tenant_id: tenant_id,
        project_id: project_id,
        status: :published,
        title: title,
        body: "telemetry deploy guide for #{title}"
      })

    {:ok, updated} = Knowledge.update_embedding(tenant_id, article.id, query_vector())
    updated
  end

  defp stub_query_embedding do
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
      {:ok, query_vector()}
    end)
  end

  defp ids(results), do: results |> Enum.map(& &1.id) |> MapSet.new()

  setup do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    other_project = fixture(:project, %{tenant_id: tenant.id})
    Knowledge.reset_circuit_breaker(tenant.id)
    stub_query_embedding()

    global = article(tenant.id, nil, "global article")
    in_project = article(tenant.id, project.id, "project article")
    other = article(tenant.id, other_project.id, "other project article")

    %{
      tenant: tenant,
      project: project,
      global: global,
      in_project: in_project,
      other: other
    }
  end

  describe "search_combined/3 :project_scope" do
    test "default (:strict) returns project-only — regression guard", ctx do
      assert {:ok, %{results: results}} =
               Knowledge.search_combined(ctx.tenant.id, "telemetry", project_id: ctx.project.id)

      got = ids(results)
      assert MapSet.member?(got, ctx.in_project.id)
      refute MapSet.member?(got, ctx.global.id), "strict must NOT include the global article"
      refute MapSet.member?(got, ctx.other.id), "strict must NOT include another project"
    end

    test "explicit :strict matches the default (project-only)", ctx do
      assert {:ok, %{results: results}} =
               Knowledge.search_combined(ctx.tenant.id, "telemetry",
                 project_id: ctx.project.id,
                 project_scope: :strict
               )

      got = ids(results)
      assert MapSet.equal?(got, MapSet.new([ctx.in_project.id]))
    end

    test ":with_global returns global ∪ project, excludes another project", ctx do
      assert {:ok, %{results: results}} =
               Knowledge.search_combined(ctx.tenant.id, "telemetry",
                 project_id: ctx.project.id,
                 project_scope: :with_global
               )

      got = ids(results)

      assert MapSet.member?(got, ctx.in_project.id),
             "with_global must include the project article"

      assert MapSet.member?(got, ctx.global.id), "with_global must include the global article"
      refute MapSet.member?(got, ctx.other.id), "with_global must still exclude another project"
    end

    test ":with_global with a nil project_id is GLOBAL-ONLY (project_id IS NULL)", ctx do
      # With no active project the `:with_global` union is global-only: a nil project_id
      # scopes to `project_id IS NULL` (matching the merged-recall contract and the
      # memory half), NOT the former no-op that returned every project's articles.
      assert {:ok, %{results: results}} =
               Knowledge.search_combined(ctx.tenant.id, "telemetry", project_scope: :with_global)

      got = ids(results)

      assert MapSet.member?(got, ctx.global.id),
             "with_global + nil must include the global article"

      refute MapSet.member?(got, ctx.in_project.id),
             "with_global + nil must exclude project articles"

      refute MapSet.member?(got, ctx.other.id),
             "with_global + nil must exclude other-project articles"
    end
  end
end
