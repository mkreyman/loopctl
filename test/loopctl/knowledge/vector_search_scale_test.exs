defmodule Loopctl.Knowledge.VectorSearchScaleTest do
  @moduledoc """
  US-27.6a scale gate (TC-27.6a.3 / TC-27.6a.4): prove the shared
  `Loopctl.Knowledge.VectorSearch` helper is HNSW-index-backed at >= prod scale
  WITH the anti-join + threshold post-filters applied, and that the worst-case
  caller parameters (threshold=0, k=max, dense hub) complete under the heavy-read
  statement_timeout — the exact #168/#170/#172 regression class, guarded on the
  real helper query with the planner's natural choice (no enable_seqscan=off).

  Seeds ~80k committed rows via `Loopctl.Knowledge.ScaleSeed`, so it is
  `:scale_nightly` (runs on the nightly/scale gate, NOT the default async suite,
  which has no seeded corpus).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.PlanAssertions
  alias Loopctl.Tenants.Tenant

  import Ecto.Query

  @moduletag :scale_nightly
  @moduletag timeout: :timer.minutes(30)

  # The pool-level heavy-read statement_timeout backstop (worst-case must beat it).
  # Reads from System env (the prod source of truth), so any operator override
  # (e.g., HEAVY_READ_STATEMENT_TIMEOUT_MS=5000) is faithfully tested here too.
  @heavy_read_statement_timeout_ms System.get_env("HEAVY_READ_STATEMENT_TIMEOUT_MS", "10000")
                                   |> String.to_integer()

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  setup do
    tenant =
      unboxed(fn ->
        slug = "vsearch-scale-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "VSearch Scale #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        # link_density: 10 → a dense, linked corpus for the worst-case anti-join.
        ScaleSeed.seed(t.id, count: ScaleSeed.prod_article_floor(), link_density: 10)
        t
      end)

    on_exit(fn ->
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

  test "candidate_query is HNSW-index-backed at prod scale WITH anti-join + threshold (TC-27.6a.3)",
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

      query =
        VectorSearch.candidate_query(tenant.id, target.embedding, 5,
          exclude_id: target.id,
          exclude_linked: true,
          threshold: 0.5
        )

      # Planner's NATURAL choice (no enable_seqscan/sort=off) at 80k must reach
      # `articles` via exactly one HNSW Index Scan — never a Seq/Bitmap full-corpus
      # read. assert_hnsw_index/1 implies refute_full_scan/1; we assert both for the
      # explicit AC-27.6a.3 mapping.
      assert :ok = PlanAssertions.refute_full_scan(query)
      assert :ok = PlanAssertions.assert_hnsw_index(query)
    end)
  end

  test "all residual filters (incl. selective tags/category) stay HNSW-index-backed at scale (AC-27.6a.3)",
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

      # This is the regression guard for the index-defeat fix. `tags`/`category` are
      # applied on the OUTER pool (NOT the index-ordered subquery) precisely BECAUSE a
      # selective `tags &&`/`category =` on the inner ANN query made the planner
      # BitmapAnd GIN(tags)+btree(category) → Sort, defeating HNSW (verified at 80k).
      # Only `visibility` (metadata->>, no servable index) remains an inner Filter.
      # ScaleSeed makes all three selective (~2% tag, ~20% category, ~10% private). The
      # planner's NATURAL choice at 80k must STILL reach `articles` via exactly one HNSW
      # Index Scan — never a Bitmap/Seq full-corpus read. DO NOT move tags/category back
      # inside the candidate subquery (re-run this test at scale if you do).
      query =
        VectorSearch.candidate_query(tenant.id, target.embedding, 5,
          exclude_id: target.id,
          exclude_linked: true,
          threshold: 0.5,
          tags: ["scale-tag-3"],
          category: :decision,
          visibility_agent_id: "scale-agent-0"
        )

      assert :ok = PlanAssertions.refute_full_scan(query)
      assert :ok = PlanAssertions.assert_hnsw_index(query)
    end)
  end

  test "worst-case caller params (threshold=0, k=max, dense hub) complete under the timeout (TC-27.6a.4)",
       %{tenant: tenant} do
    unboxed(fn ->
      # A dense-hub target: pick a row deep in the seeded corpus (link_density: 10),
      # so its nearest neighbors are heavily pre-linked — the adversarial anti-join.
      target =
        AdminRepo.one(
          from(a in Article,
            where: a.tenant_id == ^tenant.id,
            order_by: [asc: a.inserted_at, asc: a.id],
            offset: 100,
            limit: 1,
            select: %{id: a.id, embedding: a.embedding}
          )
        )

      worst_case = fn ->
        VectorSearch.nearest(tenant.id, target.embedding, VectorSearch.max_k(),
          exclude_id: target.id,
          exclude_linked: true,
          threshold: 0.0,
          tags: ["scale-tag-3"],
          category: :decision
        )
      end

      {elapsed_us, results} = :timer.tc(worst_case)
      elapsed_ms = div(elapsed_us, 1000)

      # The DESIGNED backstop is the pool-level statement_timeout; the worst case
      # must complete WELL under it on the indexed path (the whole point of the
      # correct-by-construction shape).
      assert elapsed_ms < @heavy_read_statement_timeout_ms,
             "worst-case kNN took #{elapsed_ms}ms, expected < #{@heavy_read_statement_timeout_ms}ms " <>
               "(must beat the heavy-read statement_timeout backstop)"

      assert is_list(results)
      assert length(results) <= VectorSearch.max_k()
    end)
  end
end
