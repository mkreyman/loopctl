defmodule Loopctl.MemoryRecallContextTest do
  @moduledoc """
  #411 Gap 2 (PR B): `Loopctl.Memory.recall_context/2` — the merged, re-ranked
  `global ∪ active-project` recall combining long-term MEMORY and KNOWLEDGE in one call.

  Covers: both sides merge global with the active project and EXCLUDE another project;
  the merged list is tagged per-source and sorted by score DESC; the per-source
  envelopes are returned unchanged; and a knowledge fault degrades gracefully to a
  memory-only result with `degraded?: true` (never a crash).

  Async: memory OLTP + recall route through `Loopctl.AdminRepo`/`Loopctl.HeavyRead`
  (AdminRepo in test) and knowledge through `AdminRepo`, so every path shares the one
  sandbox connection; the embedding worker runs inline during `remember/2`.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Memory.Scope

  defp article(tenant_id, project_id, title) do
    art =
      fixture(:article, %{
        tenant_id: tenant_id,
        project_id: project_id,
        status: :published,
        title: title,
        body: "reshipment policy notes for #{title}"
      })

    {:ok, updated} = Knowledge.update_embedding(tenant_id, art.id, List.duplicate(0.1, 1536))
    updated
  end

  defp mem(scope, project_id, text) do
    {:ok, m} = Memory.remember(%{scope | project_id: project_id}, %{tier: :long_term, text: text})
    m
  end

  defp memory_ids(env), do: env.results |> Enum.map(fn {m, _} -> m.id end) |> MapSet.new()
  defp knowledge_ids(env), do: env.results |> Enum.map(& &1.id) |> MapSet.new()

  setup do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    other_project = fixture(:project, %{tenant_id: tenant.id})
    Knowledge.reset_circuit_breaker(tenant.id)

    scope = %Scope{
      tenant_id: tenant.id,
      subject_id: "subject-#{System.unique_integer([:positive])}",
      project_id: project.id
    }

    %{tenant: tenant, project: project, other_project: other_project, scope: scope}
  end

  describe "recall_context/2 - merged global ∪ active-project" do
    test "merges memory + knowledge, both scopes, excludes another project", ctx do
      # Memory: global + this project + another project.
      global_mem = mem(ctx.scope, nil, "reshipment for delayed orders global")
      project_mem = mem(ctx.scope, ctx.project.id, "reshipment for delayed orders project")
      other_mem = mem(ctx.scope, ctx.other_project.id, "reshipment for delayed orders other")

      # Knowledge: global + this project + another project.
      global_art = article(ctx.tenant.id, nil, "global article")
      project_art = article(ctx.tenant.id, ctx.project.id, "project article")
      other_art = article(ctx.tenant.id, ctx.other_project.id, "other project article")

      result = Memory.recall_context(ctx.scope, query: "reshipment", limit: 20)

      # Per-source memory: global ∪ project, NOT another project.
      m_ids = memory_ids(result.memory)
      assert MapSet.member?(m_ids, global_mem.id)
      assert MapSet.member?(m_ids, project_mem.id)
      refute MapSet.member?(m_ids, other_mem.id)

      # Per-source knowledge: global ∪ project, NOT another project.
      k_ids = knowledge_ids(result.knowledge)
      assert MapSet.member?(k_ids, global_art.id)
      assert MapSet.member?(k_ids, project_art.id)
      refute MapSet.member?(k_ids, other_art.id)

      # Merged list carries BOTH source tags.
      sources = result.results |> Enum.map(& &1.source) |> MapSet.new()
      assert MapSet.equal?(sources, MapSet.new([:memory, :knowledge]))

      # Merged sorted by score DESC.
      scores = Enum.map(result.results, & &1.score)
      assert scores == Enum.sort(scores, :desc)

      # Meta accounting.
      assert result.meta.query == "reshipment"
      assert result.meta.project_id == ctx.project.id
      assert result.meta.degraded? == false
      assert result.meta.memory_count == 2
      assert result.meta.knowledge_count == 2
      assert result.meta.total_count == length(result.results)

      # Merged item shapes.
      mem_item = Enum.find(result.results, &(&1.source == :memory))
      assert %{memory: %Memory.Memory{}, score: score} = mem_item
      assert is_number(score)

      know_item = Enum.find(result.results, &(&1.source == :knowledge))
      assert %{article: %{final_score: _}, score: _} = know_item
    end

    test "a nil-project scope is global-only on BOTH memory and knowledge" do
      # With no active project the `global ∪ active-project` union is GLOBAL-ONLY on
      # BOTH sides (matching the published RecallContextRequest / MCP recall_context
      # contract). Memory's nil semantics scope to `project_id IS NULL`; knowledge's
      # `:with_global` mode ALSO scopes a nil project to `project_id IS NULL` (rather
      # than the former no-op that flooded the merged limit with every project's rows).
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      Knowledge.reset_circuit_breaker(tenant.id)

      global_scope = %Scope{
        tenant_id: tenant.id,
        subject_id: "subject-#{System.unique_integer([:positive])}",
        project_id: nil
      }

      project_scope = %{global_scope | project_id: project.id}

      global_mem = mem(global_scope, nil, "reshipment global only")
      project_mem = mem(project_scope, project.id, "reshipment project only")
      global_art = article(tenant.id, nil, "global only article")
      project_art = article(tenant.id, project.id, "project only article")

      result = Memory.recall_context(global_scope, query: "reshipment", limit: 20)

      # Memory: global-only (excludes the project-tagged memory).
      assert MapSet.equal?(memory_ids(result.memory), MapSet.new([global_mem.id]))
      refute MapSet.member?(memory_ids(result.memory), project_mem.id)

      # Knowledge: global-only too → the global article, NOT the project-tagged one.
      k_ids = knowledge_ids(result.knowledge)
      assert MapSet.member?(k_ids, global_art.id)
      refute MapSet.member?(k_ids, project_art.id)
    end
  end

  describe "recall_context/2 - graceful knowledge degradation" do
    test "an empty query degrades knowledge to memory-only with degraded?: true", ctx do
      # An empty query is a knowledge fault (`search_combined/3` → {:error, :empty_query})
      # but memory recall still returns rows — the merged call must not crash.
      project_mem = mem(ctx.scope, ctx.project.id, "reshipment kept on empty query")

      result = Memory.recall_context(ctx.scope, query: "", limit: 10)

      assert result.knowledge.results == []
      assert result.meta.knowledge_count == 0
      assert result.meta.degraded? == true

      # Memory side survived.
      assert MapSet.member?(memory_ids(result.memory), project_mem.id)
      assert Enum.all?(result.results, &(&1.source == :memory))
    end
  end

  describe "recall_context/2 - overall merged limit" do
    test "clamps the merged, re-ranked list to `limit`", ctx do
      for i <- 1..4, do: mem(ctx.scope, ctx.project.id, "reshipment memory #{i}")
      for i <- 1..4, do: article(ctx.tenant.id, ctx.project.id, "reshipment article #{i}")

      result = Memory.recall_context(ctx.scope, query: "reshipment", limit: 3)

      assert length(result.results) == 3
      assert result.meta.total_count == 3
    end
  end
end
