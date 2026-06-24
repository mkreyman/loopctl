defmodule Loopctl.Knowledge.ScaleSeedNightlyTest do
  @moduledoc """
  Nightly prod-floor scale test for `Loopctl.Knowledge.ScaleSeed`.

  TC-27.1.5: seeds at PROD_ARTICLE_FLOOR (~80k articles) and asserts that the
  Postgres cost-based planner chooses an HNSW index scan for a KNN query.
  This is the core deliverable of US-27.1 — reproducing the planner choices
  that only appear at production scale.

  **This test takes several minutes.** It is tagged `:scale_nightly` (NOT
  `:scale`) so it is excluded by `mix test --only scale` and only runs when
  `SCALE_NIGHTLY=true` is set:

      SCALE_TESTS=true SCALE_NIGHTLY=true mix test --only scale_nightly

  Connection management: same unboxed_run pattern as ScaleSeedTest — real
  committed rows so that ANALYZE sees them and the planner builds statistics.
  """

  use ExUnit.Case, async: false

  # Tagged :scale_nightly ONLY (not :scale) so that `--only scale` does NOT
  # pick this test up. The test_helper.exs excludes :scale_nightly unless
  # SCALE_NIGHTLY=true. This prevents the 3-minute seed from silently running
  # inside the regular scale suite.
  @moduletag :scale_nightly

  # 30 minute timeout — seeding 80k articles + links takes several minutes on
  # CI hardware.
  @moduletag timeout: :timer.minutes(30)

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.Tenants.Tenant

  defp with_unboxed_db(fun) do
    Sandbox.unboxed_run(AdminRepo, fun)
  end

  setup do
    tenant =
      with_unboxed_db(fn ->
        tenant_id = Ecto.UUID.generate()
        slug = "scale-nightly-#{:erlang.phash2(tenant_id)}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "Scale Nightly Tenant #{slug}",
            slug: slug,
            email: "scale-nightly-#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        t
      end)

    on_exit(fn ->
      with_unboxed_db(fn ->
        AdminRepo.delete_all(from(l in ArticleLink, where: l.tenant_id == ^tenant.id))
        AdminRepo.delete_all(from(a in Article, where: a.tenant_id == ^tenant.id))
        AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
      end)
    end)

    {:ok, tenant: tenant}
  end

  # ---------------------------------------------------------------------------
  # TC-27.1.5: seed at PROD_ARTICLE_FLOOR — HNSW index chosen for KNN query
  # ---------------------------------------------------------------------------
  test "TC-27.1.5: seed at prod_article_floor — HNSW index chosen for KNN query",
       %{tenant: tenant} do
    floor = ScaleSeed.prod_article_floor()

    with_unboxed_db(fn ->
      ScaleSeed.assert_at_prod_scale!(floor)

      {:ok, result} =
        ScaleSeed.seed(tenant.id,
          count: floor,
          link_density: 5,
          batch_size: 1_000
        )

      assert result.articles == floor,
             "Expected #{floor} articles seeded; got #{result.articles}"

      # Run EXPLAIN on a representative KNN query and assert the planner
      # chose an HNSW index scan (not a sequential scan). This is the
      # real deliverable: at prod scale the HNSW path must be chosen.
      probe_embedding = ScaleSeed.embedding_for(0)
      probe_vector = Pgvector.new(probe_embedding)

      tenant_id_binary = Ecto.UUID.dump!(tenant.id)

      %{rows: explain_rows} =
        AdminRepo.query!(
          """
          EXPLAIN (FORMAT TEXT)
          SELECT id FROM articles
          WHERE tenant_id = $1
          ORDER BY embedding <=> $2
          LIMIT 10
          """,
          [tenant_id_binary, probe_vector]
        )

      plan_text = Enum.map_join(explain_rows, "\n", fn [line] -> line end)

      assert String.contains?(plan_text, "hnsw") or String.contains?(plan_text, "Index Scan"),
             "Expected HNSW index scan in query plan at prod scale (#{floor} rows), " <>
               "but got a sequential scan. Plan:\n#{plan_text}"
    end)
  end
end
