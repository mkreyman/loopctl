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
  alias Loopctl.Repo.HnswIndex
  alias Loopctl.Tenants.Tenant

  @moduletag :scale
  @moduletag timeout: :timer.minutes(30)

  # Two distinct dimensions is the point of the story; 1536 is the hosted default
  # (the "does not regress" case) and 768 is the local-model case from GH #409.
  @gate_dimensions [768, 1536]

  # Rows must be COMMITTED (outside the sandbox transaction) for ANALYZE to build
  # real statistics — an in-sandbox seed yields n≈0 and the planner would pick a
  # Seq Scan for reasons that have nothing to do with the index.
  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

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
        end

        t
      end)

    on_exit(fn ->
      unboxed(fn ->
        AdminRepo.delete_all(from(ae in ArticleEmbedding, where: ae.tenant_id == ^tenant.id))
        AdminRepo.delete_all(from(a in Article, where: a.tenant_id == ^tenant.id))
        AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
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

    test "every supported dimension the instance publishes is covered by an index" do
      # The gate EXPLAINs two dimensions; this keeps the published set honest for
      # the rest (AC-41.1.3 / TC-41.1.8).
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
end
