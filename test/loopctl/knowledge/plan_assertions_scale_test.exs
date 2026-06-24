defmodule Loopctl.Knowledge.PlanAssertionsScaleTest do
  @moduledoc """
  US-27.2 / AC-27.2.7: prove the production `suggested_links` query shape (cosine
  ORDER BY + the article_links anti-join + threshold) is index-backed at >= prod
  scale — the exact #172 regression class, guarded on the REAL query, with the
  planner's natural choice (no enable_seqscan=off).

  AC-27.2.4: the asserted query is byte-identical to the one the request path emits.

  Seeds ~80k committed rows (Loopctl.Knowledge.ScaleSeed), so it is `:scale_nightly`
  (runs on the nightly/scale gate, not the default async suite).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.PlanAssertions
  alias Loopctl.Tenants.Tenant

  import Ecto.Query

  @moduletag :scale_nightly
  @moduletag timeout: :timer.minutes(30)

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  setup do
    tenant =
      unboxed(fn ->
        slug = "plan-scale-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "Plan Scale #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        ScaleSeed.seed(t.id, count: ScaleSeed.prod_article_floor(), link_density: 5)
        t
      end)

    on_exit(fn ->
      # Best-effort cleanup: after a long (~90s) unboxed run the pooled connection can be
      # idle-closed, and a failed cleanup must not fail the test (each run uses a fresh
      # tenant, so leftover rows are harmless in the scale DB).
      try do
        unboxed(fn ->
          AdminRepo.delete_all(from(a in Article, where: a.tenant_id == ^tenant.id))
          AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
        end)
      rescue
        _ -> :ok
      end
    end)

    {:ok, tenant: tenant}
  end

  test "suggested_links is HNSW-index-backed at prod scale, on the request-path query",
       %{tenant: tenant} do
    unboxed(fn ->
      target =
        AdminRepo.one(
          from(a in Article,
            where: a.tenant_id == ^tenant.id,
            limit: 1,
            select: %{id: a.id, embedding: a.embedding}
          )
        )

      built =
        Knowledge.suggestion_candidates_query(tenant.id, target.id, target.embedding, 0.5, 5, nil)

      {built_sql, _} = SQL.to_sql(:all, AdminRepo, built)

      # AC-27.2.4: the query we assert on is byte-identical to the one the request path
      # actually emits (no independently re-constructed stunt double).
      captured =
        PlanAssertions.capture_repo_queries(fn ->
          Knowledge.suggest_links(tenant.id, target.id, threshold: 0.5, limit: 5)
        end)

      {emitted_sql, _} =
        PlanAssertions.only_query_matching(captured, ~r/<=>.*article_links|article_links.*<=>/s)

      assert emitted_sql == built_sql,
             "Plan-assertion query and request-path query must be byte-identical (AC-27.2.4)."

      # AC-27.2.7: planner's NATURAL choice (no enable_seqscan/sort=off) at 80k must reach
      # articles via the HNSW index — not a full Seq Scan + Sort (the #172 prod 500).
      assert :ok = PlanAssertions.assert_hnsw_index(built)
    end)
  end
end
