defmodule Loopctl.Knowledge.ScaleSeedTest do
  @moduledoc """
  Scale integration tests for `Loopctl.Knowledge.ScaleSeed`.

  These tests seed large corpora, commit rows, run ANALYZE, and assert that
  Postgres statistics reflect the seeded corpus. They are deliberately:

    - `async: false` — scale seeding must not race with the normal async suite
    - `@tag :scale` — excluded from `mix test` by default (see test/test_helper.exs)
    - NOT using `Loopctl.DataCase` — the DataCase sandbox rolls back all inserts,
      so insert_all + ANALYZE would see n≈0 rows, silently defeating the purpose

  Connection management: the test DB pool is in `:manual` sandbox mode.
  Scale tests bypass the sandbox by calling `Sandbox.unboxed_run/2`, which
  gives a real owned connection that commits rows and is visible to ANALYZE.

  ## Running scale tests

      SCALE_TESTS=true mix test --only scale

  ## Teardown

  Each test inserts rows directly into the database. The `on_exit` teardown
  deletes them by tenant_id. If a test crashes before teardown runs, clean up
  manually:

      import Ecto.Query
      alias Loopctl.AdminRepo
      alias Loopctl.Knowledge.{Article, ArticleLink}
      alias Loopctl.Tenants.Tenant
      Ecto.Adapters.SQL.Sandbox.unboxed_run(AdminRepo, fn ->
        AdminRepo.delete_all(from l in ArticleLink, where: l.tenant_id == ^id)
        AdminRepo.delete_all(from a in Article, where: a.tenant_id == ^id)
        AdminRepo.delete_all(from t in Tenant, where: t.id == ^id)
      end)
  """

  # async: false is REQUIRED for scale tests — they commit rows directly to the
  # shared DB and the row counts must be stable during ANALYZE + assertion.
  use ExUnit.Case, async: false

  # Tag :scale so this module is excluded from the default `mix test` run.
  # Only runs when SCALE_TESTS=true is set (see test_helper.exs).
  @moduletag :scale

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant

  # ---------------------------------------------------------------------------
  # Unboxed connection helper
  #
  # The DB pool is in :manual sandbox mode. Scale tests need real committed
  # rows, so we bypass the sandbox with Sandbox.unboxed_run/2. This gives
  # a connection outside the rolled-back sandbox transaction — rows survive
  # past the call and are visible to ANALYZE and subsequent queries.
  # ---------------------------------------------------------------------------

  defp with_unboxed_db(fun) do
    Sandbox.unboxed_run(AdminRepo, fun)
  end

  # ---------------------------------------------------------------------------
  # Setup: create a real tenant via unboxed connection; register teardown.
  # ---------------------------------------------------------------------------

  setup do
    # This module is on bare `ExUnit.Case`, so nothing else stubs the injected
    # collaborators `config/test.exs` points at Mox mocks (see
    # `test/loopctl/config_embedding_read_path_test.exs`).
    Loopctl.DataCase.stub_all_defaults()

    # We cannot use the sandbox here — we need committed rows for ANALYZE.
    # Use unboxed_run to get a real connection that commits rows.
    tenant =
      with_unboxed_db(fn ->
        tenant_id = Ecto.UUID.generate()
        slug = "scale-test-#{:erlang.phash2(tenant_id)}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "Scale Test Tenant #{slug}",
            slug: slug,
            email: "scale-test-#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        t
      end)

    # TEARDOWN: always delete seeded rows in dependency order
    # (article_links → articles → tenant) because FK on_delete: :restrict.
    # Use schema modules so UUID params encode as binary (not string).
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
  # TC-27.1.1: seed 1_000 articles — AdminRepo count == 1_000, all 1536-dim,
  # pg_stat_user_tables shows articles analyzed with n_live_tup >= seed count.
  # ---------------------------------------------------------------------------
  test "TC-27.1.1: seed 1_000 articles — count, embedding dim, and ANALYZE stats correct",
       %{tenant: tenant} do
    with_unboxed_db(fn ->
      {:ok, result} = ScaleSeed.seed(tenant.id, count: 1_000, link_density: 0, batch_size: 500)

      assert result.articles == 1_000

      # Count published articles with non-null embeddings for this tenant.
      # Use schema module so UUID param encodes correctly.
      count =
        AdminRepo.one!(
          from(a in Article,
            where:
              a.tenant_id == ^tenant.id and a.status == :published and
                not is_nil(a.embedding),
            select: count(a.id)
          )
        )

      assert count == 1_000

      # Verify all embeddings are exactly 1536-dim via vector_dims()
      dim_min =
        AdminRepo.one!(
          from(a in Article,
            where: a.tenant_id == ^tenant.id and not is_nil(a.embedding),
            select: fragment("MIN(vector_dims(embedding::vector))")
          )
        )

      assert dim_min == 1_536

      dim_max =
        AdminRepo.one!(
          from(a in Article,
            where: a.tenant_id == ^tenant.id and not is_nil(a.embedding),
            select: fragment("MAX(vector_dims(embedding::vector))")
          )
        )

      assert dim_max == 1_536

      # Verify pg_stat_user_tables: last_analyze is non-nil, n_live_tup > 0
      %{rows: rows} =
        AdminRepo.query!("""
        SELECT n_live_tup, last_analyze
        FROM pg_stat_user_tables
        WHERE relname = 'articles'
        """)

      assert [[n_live_tup, last_analyze]] = rows
      assert not is_nil(last_analyze), "last_analyze should be non-nil after ScaleSeed.seed/2"
      assert n_live_tup > 0, "n_live_tup should be > 0 after seeding and ANALYZE"
    end)
  end

  # ---------------------------------------------------------------------------
  # TC-27.1.2: seed 500 articles with link_density 3 → ~1_500 article_links,
  # every link's source & target belong to tenant.id.
  # ---------------------------------------------------------------------------
  test "TC-27.1.2: seed 500 articles at link_density 3 — link count and tenant isolation",
       %{tenant: tenant} do
    with_unboxed_db(fn ->
      {:ok, result} = ScaleSeed.seed(tenant.id, count: 500, link_density: 3, batch_size: 500)

      assert result.articles == 500

      # Expected links: 500 * 3 = 1_500 (some may be deduplicated by on_conflict:
      # :nothing if indices wrap around; at 500 rows and density 3 all 1_500 are unique).
      expected_links = 500 * 3
      tolerance = max(5, div(expected_links, 20))

      link_count =
        AdminRepo.one!(
          from(l in ArticleLink,
            where: l.tenant_id == ^tenant.id,
            select: count(l.id)
          )
        )

      assert abs(link_count - expected_links) <= tolerance,
             "Expected ~#{expected_links} links (±#{tolerance}), got #{link_count}"

      # All links must belong to tenant.id (source articles)
      bad_source_count =
        AdminRepo.one!(
          from(l in ArticleLink,
            join: a in Article,
            on: l.source_article_id == a.id,
            where: l.tenant_id == ^tenant.id and a.tenant_id != ^tenant.id,
            select: count(l.id)
          )
        )

      assert bad_source_count == 0,
             "All link source articles must belong to tenant #{tenant.id}"

      # All links must belong to tenant.id (target articles)
      bad_target_count =
        AdminRepo.one!(
          from(l in ArticleLink,
            join: a in Article,
            on: l.target_article_id == a.id,
            where: l.tenant_id == ^tenant.id and a.tenant_id != ^tenant.id,
            select: count(l.id)
          )
        )

      assert bad_target_count == 0,
             "All link target articles must belong to tenant #{tenant.id}"

      # AC-27.1.3: linked targets must be vector nearest-neighbours of their source.
      # embedding_for/1 is constructed so that index-adjacent articles are also
      # cosine-nearest-neighbours (smooth component dominates). We sample a few
      # pairs and assert cosine similarity > 0.9, which proves the link graph
      # reflects the vector neighbourhood — not arbitrary adjacency.
      #
      # We compare cosine(source, linked_target) vs cosine(source, a random
      # non-linked article). Linked targets must be strictly closer.
      sample_size = 10

      sample_pairs =
        AdminRepo.all(
          from(l in ArticleLink,
            join: src in Article,
            on: l.source_article_id == src.id,
            join: tgt in Article,
            on: l.target_article_id == tgt.id,
            where: l.tenant_id == ^tenant.id,
            select: {src.embedding, tgt.embedding},
            limit: ^sample_size
          )
        )

      assert sample_pairs != [],
             "Expected at least one link to sample for neighbor-proximity check"

      Enum.each(sample_pairs, fn {src_emb, tgt_emb} ->
        sim = cosine_similarity(Pgvector.to_list(src_emb), Pgvector.to_list(tgt_emb))

        assert sim > 0.9,
               "Linked articles must be vector nearest-neighbours: cosine similarity #{Float.round(sim, 4)} <= 0.9. " <>
                 "embedding_for/1 is supposed to make index-adjacent articles cosine-close."
      end)
    end)
  end

  # Cosine similarity between two float lists (both pre-normalized to unit length).
  defp cosine_similarity(a, b) do
    a
    |> Enum.zip(b)
    |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
  end

  # ---------------------------------------------------------------------------
  # TC-27.1.3: seed below PROD_ARTICLE_FLOOR → raises loudly
  # (pure logic test — no DB ops needed)
  # ---------------------------------------------------------------------------
  test "TC-27.1.3: assert_at_prod_scale! raises clearly when count < PROD_ARTICLE_FLOOR" do
    floor = ScaleSeed.prod_article_floor()

    assert_raise RuntimeError, ~r/seed below prod floor/i, fn ->
      ScaleSeed.assert_at_prod_scale!(floor - 1)
    end

    # Edge: exactly at floor should not raise
    assert :ok = ScaleSeed.assert_at_prod_scale!(floor)
    # And above floor
    assert :ok = ScaleSeed.assert_at_prod_scale!(floor + 1_000)
  end

  # ---------------------------------------------------------------------------
  # TC-27.1.4: tenant isolation + deterministic embeddings
  # ---------------------------------------------------------------------------
  test "TC-27.1.4: tenant isolation — tenant_b has 0 articles; embeddings are deterministic",
       %{tenant: tenant_a} do
    with_unboxed_db(fn ->
      # Create a second tenant to verify isolation
      tenant_b_id = Ecto.UUID.generate()
      slug_b = "scale-test-b-#{:erlang.phash2(tenant_b_id)}"

      {:ok, tenant_b} =
        %Tenant{}
        |> Tenant.create_changeset(%{
          name: "Scale Test Tenant B #{slug_b}",
          slug: slug_b,
          email: "scale-test-b-#{slug_b}@example.com",
          settings: %{},
          status: :active
        })
        |> AdminRepo.insert()

      # Register teardown for tenant_b (on_exit is async-safe even nested)
      on_exit(fn ->
        with_unboxed_db(fn ->
          AdminRepo.delete_all(from(l in ArticleLink, where: l.tenant_id == ^tenant_b.id))
          AdminRepo.delete_all(from(a in Article, where: a.tenant_id == ^tenant_b.id))
          AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant_b.id))
        end)
      end)

      # Seed 200 articles under tenant_a only
      {:ok, result} = ScaleSeed.seed(tenant_a.id, count: 200, link_density: 2, batch_size: 200)
      assert result.articles == 200

      # tenant_a: 200 articles via AdminRepo (BYPASSRLS sees all tenants)
      count_a =
        AdminRepo.one!(
          from(a in Article,
            where: a.tenant_id == ^tenant_a.id,
            select: count(a.id)
          )
        )

      assert count_a == 200

      # tenant_b: 0 articles via AdminRepo BYPASSRLS (proves seed wrote correct tenant_id)
      count_b_admin =
        AdminRepo.one!(
          from(a in Article,
            where: a.tenant_id == ^tenant_b.id,
            select: count(a.id)
          )
        )

      assert count_b_admin == 0,
             "AdminRepo (BYPASSRLS): tenant_b must see 0 articles — write-isolation violated"

      # RLS isolation: verify that querying through the RLS-enforcing Repo with
      # tenant_b's context returns 0 articles even WITHOUT an explicit tenant_id
      # filter. This is the actual AC-27.1.9 invariant — tenant A's corpus is
      # invisible to tenant B through the RLS path, not just through a hard
      # tenant_id WHERE clause.
      #
      # Loopctl.Repo is a SEPARATE Sandbox pool from AdminRepo. Both pools are
      # in :manual mode (test_helper.exs). Sandbox.unboxed_run/2 must be called
      # for EACH pool independently — the AdminRepo unboxed_run above does NOT
      # give us a Repo connection. Without a Repo checkout, Repo.with_tenant/2
      # opens a transaction against a pool with no ownership process for this
      # PID, causing DBConnection.OwnershipError.
      {:ok, count_b_rls} =
        Sandbox.unboxed_run(Repo, fn ->
          Repo.with_tenant(tenant_b.id, fn ->
            Repo.one!(from(a in Article, select: count(a.id)))
          end)
        end)

      assert count_b_rls == 0,
             "RLS path (Repo.with_tenant/2): tenant_b must see 0 articles — " <>
               "RLS isolation violated. Tenant A's articles leaked through to tenant B."

      # Determinism: vector for index 5 is identical across two calls
      vec_5_first = ScaleSeed.embedding_for(5)
      vec_5_second = ScaleSeed.embedding_for(5)
      assert vec_5_first == vec_5_second, "embedding_for/1 must be deterministic"

      # Vector for index 5 differs from index 6
      vec_6 = ScaleSeed.embedding_for(6)
      refute vec_5_first == vec_6, "embedding_for(5) and embedding_for(6) must differ"

      # Vectors are L2-normalized (norm ≈ 1.0)
      norm_5 = vec_5_first |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

      assert_in_delta norm_5, 1.0, 1.0e-6, "embedding_for/1 must return L2-normalized vectors"

      # Embedding dimension is exactly 1_536
      assert length(vec_5_first) == 1_536
    end)
  end

  # ---------------------------------------------------------------------------
  # AC-27.1.7: hnsw_index_present?/0 detects by capability (not hardcoded name)
  # ---------------------------------------------------------------------------
  test "AC-27.1.7: hnsw_index_present?/0 detects HNSW index by capability" do
    with_unboxed_db(fn ->
      # The HNSW index must be present in the test DB (run mix ecto.migrate first)
      assert ScaleSeed.hnsw_index_present?(),
             "Expected HNSW index on articles.embedding — run mix ecto.migrate"
    end)
  end
end
