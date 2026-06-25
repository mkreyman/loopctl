defmodule Loopctl.Knowledge.TopkEndpointsScaleTest do
  @moduledoc """
  US-27.7a scale gate (TC-27.7a.3 / AC-27.7a.6): prove the three single-target top-k
  vector endpoints — `suggested_links`, `search_semantic` (RESULTS + COUNT), and the
  auto-link worker's similarity lookup — are each HNSW-index-backed (no unbounded full
  scan) and under budget at the >= prod-floor 80k corpus, now that US-27.7a routed them
  all through `Loopctl.Knowledge.VectorSearch`.

  This is the gate that makes "migrated through the helper" mean "index-correct at scale,
  proven by the planner's NATURAL choice" (no `enable_seqscan=off`). It asserts on the
  REAL request-path query builders (`Knowledge.suggestion_candidates_query/6`,
  `Knowledge.semantic_results_query/3`, `Knowledge.semantic_count_query/4`, and
  `VectorSearch.candidate_query/4` as the worker invokes it), not re-built stunt doubles
  (AC-27.2.4).

  Seeds ~80k committed rows via `Loopctl.Knowledge.ScaleSeed`, so it is `:scale_nightly`
  (runs on the nightly/scale gate, NOT the default async suite) and is wired into
  `.github/workflows/ci.yml`'s `scale_file` matrix (enforced by
  `scale_verification_runbook_test.exs`).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.PlanAssertions
  alias Loopctl.Tenants.Tenant

  import Ecto.Query

  @moduletag :scale_nightly
  @moduletag timeout: :timer.minutes(30)

  # The pool-level heavy-read statement_timeout backstop (worst-case must beat it).
  @heavy_read_statement_timeout_ms System.get_env("HEAVY_READ_STATEMENT_TIMEOUT_MS", "10000")
                                   |> String.to_integer()

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  setup do
    tenant =
      unboxed(fn ->
        slug = "topk-scale-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "Topk Scale #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        # link_density: 5 (the prod-floor default) — enough links for the suggested_links
        # anti-join to be real without the 10-dense special-casing the under-fill gate needs.
        ScaleSeed.seed(t.id, count: ScaleSeed.prod_article_floor(), link_density: 5)
        t
      end)

    # US-27.8 AC-27.8.3: calibration guard — every assertion below assumes a >= prod-floor
    # corpus for THIS tenant; a sub-floor seed would make the index-usage gate false-green,
    # so fail loudly here instead.
    unboxed(fn -> PlanAssertions.assert_scale_floor!(tenant.id) end)

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

  defp a_target(tenant) do
    AdminRepo.one(
      from(a in Article,
        where: a.tenant_id == ^tenant.id and not is_nil(a.embedding),
        order_by: [asc: a.inserted_at, asc: a.id],
        offset: 100,
        limit: 1,
        select: %{id: a.id, embedding: a.embedding}
      )
    )
  end

  # ---- suggested_links (AC-27.7a.1) ----

  test "suggested_links is HNSW-index-backed at prod scale through the helper", %{tenant: tenant} do
    unboxed(fn ->
      target = a_target(tenant)

      query =
        Knowledge.suggestion_candidates_query(tenant.id, target.id, target.embedding, 0.5, 5, nil)

      # Planner's NATURAL choice at 80k must reach `articles` via exactly one HNSW Index
      # Scan — never a Seq/Bitmap full-corpus read (the #170/#172 shape).
      assert :ok = PlanAssertions.refute_full_scan(query)
      assert :ok = PlanAssertions.assert_hnsw_index(query)
    end)
  end

  # ---- search_semantic RESULTS (AC-27.7a.2 / AC-27.7a.6) ----

  test "search_semantic RESULTS stay HNSW-index-backed at scale — no-filter, deep offset, AND selective filters",
       %{tenant: tenant} do
    unboxed(fn ->
      target = a_target(tenant)
      qemb = VectorSearch.to_embedding_list(target.embedding)

      scenarios = [
        {"no filter", []},
        {"deep offset", [offset: 200]},
        # The regression case: a selective tags+category that pre-27.7a flipped the
        # index-ordered scan to BitmapAnd + Sort (abandoning HNSW). Now applied on the
        # OUTER pool, the inner ANN must STILL be a single HNSW Index Scan.
        {"selective category+tags", [category: :decision, tags: ["scale-tag-3"]]}
      ]

      for {label, opts} <- scenarios do
        query = Knowledge.semantic_results_query(tenant.id, qemb, opts)

        assert :ok = PlanAssertions.refute_full_scan(query),
               "search_semantic RESULTS (#{label}) must not full-scan at 80k"

        assert :ok = PlanAssertions.assert_hnsw_index(query),
               "search_semantic RESULTS (#{label}) must reach articles via one HNSW Index Scan"
      end
    end)
  end

  # ---- search_semantic COUNT (AC-27.7a.2 / AC-27.7a.6) ----

  test "search_semantic COUNT is sort-free, and selective counts stay index-bounded (no Seq Scan)",
       %{tenant: tenant} do
    unboxed(fn ->
      qemb = VectorSearch.to_embedding_list(a_target(tenant).embedding)

      # No-filter count: counting the whole tenant's embedded corpus is inherently
      # O(tenant rows) (a true `count(*)`), so a bounded tenant scan is correct — the
      # REGRESSION we guard is the pre-27.7a pointless full-corpus Sort (the count used to
      # wrap the results subquery's `ORDER BY embedding <=> …`). The corrected count carries
      # no ordering → the plan must be Sort-FREE.
      no_filter_count = Knowledge.semantic_count_query(tenant.id, qemb, :published, [])
      assert :ok = PlanAssertions.refute_sort(no_filter_count)

      # Selective category+tags count: must be served by the filter indexes (BitmapAnd),
      # never an unbounded Seq Scan over the corpus, and bounded by the residual
      # selectivity (well below the 80k corpus).
      selective_count =
        Knowledge.semantic_count_query(tenant.id, qemb, :published,
          category: :decision,
          tags: ["scale-tag-3"]
        )

      assert :ok = PlanAssertions.refute_sort(selective_count)
      assert :ok = PlanAssertions.refute_seq_scan(selective_count)
      assert :ok = PlanAssertions.assert_scan_rows_below(selective_count, 20_000)
    end)
  end

  # ---- auto-link worker lookup (AC-27.7a.3) ----

  test "the auto-link worker's similarity lookup is HNSW-index-backed at scale", %{tenant: tenant} do
    unboxed(fn ->
      target = a_target(tenant)
      max_comparisons = Application.get_env(:loopctl, :article_link_max_comparisons, 50)

      # The EXACT query the worker now builds (US-27.7a): VectorSearch.nearest/4 with the
      # worker's project scope on the OUTER pool, threshold 0.0 (the worker keeps its
      # inclusive >= filter in memory), and a generously-sized pool.
      query =
        VectorSearch.candidate_query(tenant.id, target.embedding, max_comparisons,
          exclude_id: target.id,
          project_or_global: nil,
          threshold: 0.0,
          pool: VectorSearch.pool_size(max_comparisons)
        )

      assert :ok = PlanAssertions.refute_full_scan(query)
      assert :ok = PlanAssertions.assert_hnsw_index(query)

      # And the worst case completes WELL under the heavy-read statement_timeout backstop.
      {elapsed_us, results} =
        :timer.tc(fn ->
          VectorSearch.nearest(tenant.id, target.embedding, max_comparisons,
            exclude_id: target.id,
            project_or_global: nil,
            threshold: 0.0,
            pool: VectorSearch.pool_size(max_comparisons)
          )
        end)

      elapsed_ms = div(elapsed_us, 1000)

      assert elapsed_ms < @heavy_read_statement_timeout_ms,
             "worker lookup took #{elapsed_ms}ms, expected < #{@heavy_read_statement_timeout_ms}ms"

      assert is_list(results)
    end)
  end
end
