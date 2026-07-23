defmodule Loopctl.Knowledge.EmbeddingDimensionPlanScaleTest do
  @moduledoc """
  US-41.1 AC-41.1.12(i) / TC-41.1.2 — the CI ACCEPTANCE GATE for the per-dimension
  ANN index.

  EXPLAINs the REAL dimension-scoped semantic-search inner query for EACH supported
  dimension against a SEEDED, COMMITTED corpus and asserts the plan shape:

    * the per-dimension index (`article_embeddings_hnsw_dim_<N>_idx`) is the CHOSEN
      path — not merely an eligible one;
    * NO `Seq Scan` reaches the vector relation;
    * the assertion is made WITHOUT `enable_seqscan = off`. Eligibility is not
      selection: forcing the planner would let a genuine cost regression pass.

  The production EXPLAIN of AC-41.1.12(ii) is an ATTACHED ARTIFACT REPORT against
  the story, deliberately NOT part of this gate — a criterion needing production DB
  access and a non-deterministic corpus can never be re-executed by the Epic 26
  verification runner, so making it the gate would reduce the story's most
  important performance claim to a human self-assertion.

  Runs OUTSIDE the DataCase sandbox (rows must be COMMITTED for `ANALYZE` to build
  real statistics — an in-sandbox seed yields n≈0 stats and silently defeats the
  gate), so it is `:scale`-tagged and torn down explicitly.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Memory.MemoryEmbedding
  alias Loopctl.Memory.Scope
  alias Loopctl.PlanAssertions
  alias Loopctl.Repo.HnswIndex
  alias Loopctl.Tenants.Tenant

  @moduletag :scale
  # ALSO :scale_nightly (review #12/#17): the every-PR job runs `--only scale` with
  # EMBEDDING_PLAN_GATE_DIMENSIONS=1536 (one dimension), while the schedule-only
  # scale-nightly matrix runs `--only scale_nightly` with the var UNSET, so the FULL
  # supported set (768/1024/1536, article + memory) is plan-gated there. An ExUnit
  # `--only` include wins over the configured exclude, so both selectors reach this file.
  @moduletag :scale_nightly
  @moduletag timeout: :timer.minutes(60)

  # EVERY supported dimension is gateable; WHICH ones run is set by the
  # `EMBEDDING_PLAN_GATE_DIMENSIONS` env var (review #12 + #17).
  #
  #   * every-PR CI sets it to the hosted default (1536) — one dimension, ~30k rows,
  #     so the per-PR seed cost stays bounded (the old hardcoded [768, 1536] seeded
  #     60k HNSW-indexed rows on every push, and the ci.yml comment claimed it covered
  #     "every supported dimension", which was false for 1024);
  #   * the scale-nightly matrix leaves it unset, so the FULL supported set runs —
  #     1024 included, with a real plan assertion rather than the pg_class index
  #     existence check that was standing in for one.
  @gate_dimensions (case System.get_env("EMBEDDING_PLAN_GATE_DIMENSIONS") do
                      nil ->
                        Application.compile_env(
                          :loopctl,
                          :supported_embedding_dimensions,
                          [768, 1024, 1536]
                        )

                      csv ->
                        csv
                        |> String.split(",", trim: true)
                        |> Enum.map(&String.to_integer(String.trim(&1)))
                    end)
                   |> Enum.filter(&(&1 <= 2000))
                   |> Enum.sort()

  # Rows must be COMMITTED (outside the sandbox transaction) for ANALYZE to build
  # real statistics — an in-sandbox seed yields n≈0 and the planner would pick a
  # Seq Scan for reasons that have nothing to do with the index.
  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  setup do
    # `config/test.exs` points `:embedding_read_path` at a Mox mock for the whole test
    # env, and this module does not `use Loopctl.DataCase`, so nothing has stubbed it.
    # Any read reaching `Embeddings.side_table_reads_enabled?/0` would otherwise raise
    # `Mox.UnexpectedCallError` in the nightly scale job. Per-test (not `setup_all`):
    # a Mox stub is registered against the CALLING process, and `setup_all` runs in a
    # different one.
    Loopctl.DataCase.stub_embedding_read_path()
    :ok
  end

  setup_all do
    tenant =
      unboxed(fn ->
        t =
          AdminRepo.insert!(%Tenant{
            name: "US-41.1 plan gate",
            slug: "us411-plan-gate-#{System.unique_integer([:positive])}",
            email: "us411-#{System.unique_integer([:positive])}@example.test",
            status: :active
          })

        for dim <- @gate_dimensions do
          {:ok, _} = ScaleSeed.seed_embedding_side_table(t.id, dim)
          {:ok, _} = ScaleSeed.seed_memory_embedding_side_table(t.id, dim)
        end

        t
      end)

    on_exit(fn ->
      unboxed(fn ->
        # ScaleSeed.plan_gate_corpus_size/0 HNSW-indexed rows per relation per
        # dimension. Deleting them runs index maintenance, and the default 15s Ecto
        # statement timeout is not enough for a delete this size — the connection
        # drops mid-teardown ("tcp recv (idle): closed") and ExUnit reports it as a
        # setup_all failure that invalidates every PASSING plan assertion. Note
        # `ownership_timeout` (raised to 30 min in config/test.exs) does NOT cover
        # this: it bounds connection CHECKOUT, not statement execution. So each delete
        # carries an explicit generous statement timeout.
        del_opts = [timeout: :timer.minutes(10)]

        AdminRepo.delete_all(
          from(me in MemoryEmbedding, where: me.tenant_id == ^tenant.id),
          del_opts
        )

        AdminRepo.delete_all(from(m in MemorySchema, where: m.tenant_id == ^tenant.id), del_opts)

        AdminRepo.delete_all(
          from(ae in ArticleEmbedding, where: ae.tenant_id == ^tenant.id),
          del_opts
        )

        AdminRepo.delete_all(from(a in Article, where: a.tenant_id == ^tenant.id), del_opts)
        AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id), del_opts)
      end)
    end)

    {:ok, tenant: tenant}
  end

  describe "per-dimension ANN plan (TC-41.1.2)" do
    for dim <- @gate_dimensions do
      test "dim #{dim}: the per-dimension index is CHOSEN, with no Seq Scan on the vector relation",
           %{tenant: tenant} do
        dim = unquote(dim)
        plan = unboxed(fn -> explain_ann(tenant.id, dim) end)

        expected_index = HnswIndex.dimension_index_name("article_embeddings", dim)

        assert plan =~ expected_index,
               "expected the plan to use #{expected_index}, got:\n#{plan}"

        refute plan =~ ~r/Seq Scan on article_embeddings/,
               "a Seq Scan reached the vector relation:\n#{plan}"
      end
    end

    test "the corpus is genuinely large enough that the gate means something", %{tenant: tenant} do
      for dim <- @gate_dimensions do
        count =
          unboxed(fn ->
            AdminRepo.aggregate(
              from(ae in ArticleEmbedding, where: ae.tenant_id == ^tenant.id and ae.dim == ^dim),
              :count
            )
          end)

        assert count >= ScaleSeed.plan_gate_corpus_size(),
               "seeded #{count} rows at dim #{dim} — below the measured Seq-Scan/HNSW " <>
                 "crossover, so a passing plan would prove nothing"
      end
    end

    for dim <- @gate_dimensions do
      test "dim #{dim}: MEMORY recall's per-dimension index is CHOSEN too",
           %{tenant: tenant} do
        dim = unquote(dim)
        plan = unboxed(fn -> explain_memory_ann(tenant.id, dim) end)

        expected_index = HnswIndex.dimension_index_name("memory_embeddings", dim)

        assert plan =~ expected_index,
               "expected the plan to use #{expected_index}, got:\n#{plan}"

        refute plan =~ ~r/Seq Scan on memory_embeddings/,
               "a Seq Scan reached the memory vector relation:\n#{plan}"
      end
    end

    for dim <- @gate_dimensions do
      test "dim #{dim}: the SIDE-TABLE novelty aggregate is bounded, not a full scan",
           %{tenant: tenant} do
        dim = unquote(dim)

        # REVIEW: the side-table branch of `novelty_distance_query/4` replaces the
        # legacy inline `tags &&` residual with an `ae.article_id IN (subquery)`
        # semi-join over `article_embeddings` — a materially different residual, and
        # the existing US-27.7b gate EXPLAINs the query builder with the cutover flag
        # OFF, so it kept gating the LEGACY shape only. This gates the shape the
        # request path actually runs after cutover.
        query =
          Knowledge.novelty_distance_side_table_query(
            tenant.id,
            ScaleSeed.embedding_for(3, dim),
            ScaleSeed.plan_gate_prior_tag(),
            nil,
            dim
          )

        unboxed(fn ->
          assert :ok = PlanAssertions.refute_seq_scan(query)

          # Bounded by the ~2% prior tag, NOT by the corpus: the ceiling is
          # comfortably above the tag set and far below the seeded corpus.
          assert :ok =
                   PlanAssertions.assert_actual_scan_rows_below(
                     query,
                     div(ScaleSeed.plan_gate_corpus_size(), 4)
                   )
        end)
      end

      test "dim #{dim}: the SIDE-TABLE suggest-links/dedup candidate pool is index-served",
           %{tenant: tenant} do
        dim = unquote(dim)

        query =
          VectorSearch.dimension_candidate_pool_query(
            tenant.id,
            ScaleSeed.embedding_for(5, dim),
            50,
            dimension: dim
          )

        plan = unboxed(fn -> AdminRepo.explain(:all, query) end)

        # `suggest_links`, the novelty/dedup gate and `ArticleLinkingWorker` all route
        # through this helper — it was never plan-gated on the side-table branch.
        assert plan =~ HnswIndex.dimension_index_name("article_embeddings", dim),
               "expected the per-dimension index, got:\n#{plan}"

        refute plan =~ ~r/Seq Scan on article_embeddings/,
               "a Seq Scan reached the vector relation:\n#{plan}"
      end

      test "dim #{dim}: the SIDE-TABLE distant-pairs candidate set stays LIMIT-bounded",
           %{tenant: tenant} do
        dim = unquote(dim)
        query = Knowledge.pair_candidates_side_table_query(tenant.id, false, nil, dim)

        # No `$const` target vector exists here (both operands are stored columns), so
        # HNSW cannot apply BY NATURE — the invariant is the sampled LIMIT, exactly as
        # for the legacy shape.
        unboxed(fn ->
          assert :ok =
                   PlanAssertions.assert_actual_scan_rows_below(
                     query,
                     ScaleSeed.plan_gate_corpus_size()
                   )
        end)
      end
    end

    for dim <- @gate_dimensions do
      test "dim #{dim}: the per-dimension index is chosen even under a FORCED GENERIC plan",
           %{tenant: tenant} do
        dim = unquote(dim)

        # Review, finding 2: `Repo.explain` on a fresh parameterized query yields a
        # CUSTOM plan, where `dim = $n` matches the partial index by value substitution —
        # so the ordinary gate cannot observe the PRODUCTION generic-plan case
        # (`plan_cache_mode=auto` flips a prepared statement to generic after ~5 runs). If
        # the dim predicate were a BOUND param, a generic plan could not prove `dim = $n`
        # implies `dim = 768` and would revert to a seq scan (#170/#172). With the dim
        # WHERE now a compile-time LITERAL (finding 1), the partial index matches
        # regardless of plan mode — this forces a generic plan and proves it.
        plan = unboxed(fn -> explain_ann_forcing_generic_plan(tenant.id, dim) end)

        expected_index = HnswIndex.dimension_index_name("article_embeddings", dim)

        assert plan =~ expected_index,
               "under force_generic_plan the plan did NOT use #{expected_index} — the dim " <>
                 "predicate is not matching the partial index under a generic plan:\n#{plan}"

        refute plan =~ ~r/Seq Scan on article_embeddings/,
               "a Seq Scan reached the vector relation under a generic plan:\n#{plan}"
      end
    end

    test "every supported dimension the instance publishes is covered by an index" do
      # The gate EXPLAINs the configured dimensions; this keeps the published set
      # honest for any not selected in this run (AC-41.1.3 / TC-41.1.8).
      for dim <- Embeddings.supported_dimensions(),
          table <- ["article_embeddings", "memory_embeddings"] do
        name = HnswIndex.dimension_index_name(table, dim)

        assert %{rows: [[1]]} =
                 unboxed(fn ->
                   AdminRepo.query!("SELECT 1 FROM pg_class WHERE relname = $1", [name])
                 end)
      end
    end
  end

  # The REAL REQUEST-PATH inner ANN — `Knowledge.semantic_side_table_pool_query/4`,
  # the exact query `Knowledge.search_semantic/3` runs through `HeavyRead` once the
  # cutover flag is on — explained through AdminRepo so no sandbox transaction
  # distorts the plan. No `enable_seqscan` manipulation of any kind. Asserting on a
  # hand-written lookalike instead would let the request path regress silently.
  defp explain_ann(tenant_id, dim) do
    target = ScaleSeed.embedding_for(7, dim)

    AdminRepo.explain(:all, Knowledge.semantic_side_table_pool_query(tenant_id, target, dim, 100))
  end

  # EXPLAIN the SAME inner ANN under `plan_cache_mode = force_generic_plan`, which
  # makes the planner build a GENERIC plan for the prepared statement immediately —
  # the steady state production reaches under `plan_cache_mode = auto` after ~5
  # executions. Proving the plan shape holds there is the whole point of the dim
  # predicate being a compile-time LITERAL rather than a bound `$n` param.
  #
  # This deliberately does NOT use `AdminRepo.explain/2`: that opens its OWN
  # transaction and `Repo.rollback`s it, which — nested inside the transaction that
  # carries the `SET LOCAL` — poisons the outer transaction to `{:error, :rollback}`.
  # So the query is rendered to SQL and EXPLAINed by hand in the SAME transaction as
  # the `SET LOCAL`. EXPLAIN without ANALYZE does not execute the query, so there is
  # nothing to roll back for correctness.
  defp explain_ann_forcing_generic_plan(tenant_id, dim) do
    target = ScaleSeed.embedding_for(7, dim)

    {sql, params} =
      AdminRepo.to_sql(
        :all,
        Knowledge.semantic_side_table_pool_query(tenant_id, target, dim, 100)
      )

    {:ok, plan} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!("SET LOCAL plan_cache_mode = force_generic_plan")
        %{rows: rows} = AdminRepo.query!("EXPLAIN (FORMAT TEXT) " <> sql, params)
        Enum.map_join(rows, "\n", fn [line] -> line end)
      end)

    plan
  end

  # The REAL memory-recall request-path inner ANN, for the same reason: the
  # `(embedding::vector(N))` cast must match the per-dimension index verbatim.
  defp explain_memory_ann(tenant_id, dim) do
    target = ScaleSeed.embedding_for(11, dim)
    scope = %Scope{tenant_id: tenant_id, subject_id: "us411-plan-gate"}

    # Memory recall resolves the dimension from the TENANT (there is no explicit
    # dimension argument on that path), so the tenant is pinned to the dimension
    # under test before the query is built.
    {:ok, _} = Embeddings.set_tenant_dimension(tenant_id, dim)

    AdminRepo.explain(
      :all,
      Memory.memory_side_table_candidate_query(scope, target, 10, false)
    )
  end
end
