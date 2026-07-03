defmodule Loopctl.Knowledge.DistantPairsNoveltyScaleTest do
  @moduledoc """
  US-27.7b AC-27.7b.4 scale gate: prove the two cosine shapes that are deliberately NOT
  `VectorSearch.nearest/4` (see `Loopctl.Knowledge.CosineLintExceptions`) do NOT full-scan
  the corpus at >= prod scale, each on its OWN bounded shape:

    * `distant_pairs` — the column-to-column self-join reads `articles` ONLY through the
      `LIMIT max_pair_candidates()` SAMPLED subquery, so every base-table scan is bounded
      by the sample cap (NOT an O(n²)/Seq read over the whole 80k corpus).
    * `novelty` (`nearest_prior_distance` → `novelty_distance_query/4`) — the `MIN(<=>)`
      aggregate is bounded by prior-tag selectivity, NOT a full-corpus read. The planner
      picks by cost between TWO bounded plans: an HNSW `ORDER BY <=> LIMIT 1` rewrite of the
      MIN (verified at 80k — `articles_embedding_hnsw_idx`, `tags &&` as a Filter) OR a
      `tags &&` GIN-bounded scan (`articles_tags_index`). The test asserts the structural
      invariant (no unbounded Seq Scan + every `articles` scan touches fewer than a small
      multiple of the tag's ~2% selectivity in ACTUAL rows, via EXPLAIN ANALYZE), accepting
      EITHER plan — it does NOT pin the node type, so a legitimate planner switch to the GIN
      bitmap can't false-RED it, while a low-estimate/high-actual full-corpus regression IS
      caught by real rows.

  The bounds are checked under the planner's NATURAL choice (no enable_seqscan=off) against
  the committed, ANALYZEd ~80k corpus from `Loopctl.Knowledge.ScaleSeed`:

    * distant_pairs: EXPLAIN on the ACTUAL pairs SQL the request path emits (captured via
      `PlanAssertions.capture_repo_queries/1` — a SINGLE `LIMIT limit+1` page query post
      #202/#203; the old companion `count(*)` full-pass is gone), asserting the
      `Limit ≤ max_pair_candidates` sample cap dominates every `articles` scan.
    * novelty: EXPLAIN ANALYZE on `novelty_distance_query/4` (the MIN runs inside a
      `Task.async_stream`, off the test process, so capture can't see it — the builder emits
      the identical SQL+params), asserting ACTUAL `articles` rows stay bounded.

  Seeds ~80k committed rows, so this is `:scale_nightly` (runs on the nightly/scale gate,
  NOT the default async suite which has no seeded corpus).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.PlanAssertions
  alias Loopctl.Tenants.Tenant

  import Ecto.Query

  @moduletag :scale_nightly
  @moduletag timeout: :timer.minutes(30)

  # The operator-tunable candidate cap (config/test.exs sets it to 25). The sampled
  # candidate subquery — and therefore every `articles` base-table scan in distant_pairs —
  # must read no more than this (with generous headroom for the planner's row estimate).
  @max_pair_candidates Application.compile_env(:loopctl, :max_pair_candidates, 1_000)

  # The tag ScaleSeed stamps on ~2% of rows (one of 50). Used as the novelty prior_tag so
  # the `tags &&` residual is genuinely selective at 80k.
  @prior_tag "scale-tag-3"

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  # `async: false` + a stub the off-process `Task.async_stream` novelty workers must see:
  # `set_mox_global` makes the embedding stub visible from any process (not just the test
  # pid's `$callers` chain). No `expect`/`verify_on_exit!` — we only `stub`.
  setup_all do
    Mox.set_mox_global()
    # The deterministic idea embedding the novelty test scores against (a real seeded
    # vector). Stubbed in THIS (the global-owner) process — global mode only lets the
    # owner set stubs, and the off-process Task.async_stream workers read it globally.
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
      {:ok, ScaleSeed.embedding_for(0)}
    end)

    :ok
  end

  setup do
    tenant =
      unboxed(fn ->
        slug = "dp-novelty-scale-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "DP/Novelty Scale #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        ScaleSeed.seed(t.id, count: ScaleSeed.prod_article_floor(), link_density: 10)
        t
      end)

    # US-27.8 AC-27.8.3: calibration guard — the distant_pairs/novelty bounds below assume
    # a >= prod-floor corpus for THIS tenant; fail loudly on a sub-floor seed.
    unboxed(fn -> PlanAssertions.assert_scale_floor!(tenant.id) end)

    on_exit(fn ->
      try do
        unboxed(fn ->
          # Delete links BEFORE articles: article_links has `on_delete: :restrict`, so
          # deleting the seeded (linked) articles first raises an FK violation, which the
          # rescue would swallow — leaving the whole ~80k committed corpus behind to
          # pollute later runs of the shared test DB (a slow `find_orphan_articles` etc.).
          AdminRepo.delete_all(from(l in ArticleLink, where: l.tenant_id == ^tenant.id))
          AdminRepo.delete_all(from(a in Article, where: a.tenant_id == ^tenant.id))
          AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
        end)
      rescue
        _ -> :ok
      end
    end)

    {:ok, tenant: tenant}
  end

  test "distant_pairs reads articles ONLY through the bounded sample (no full corpus scan)",
       %{tenant: tenant} do
    unboxed(fn ->
      # Capture the ACTUAL count + pairs SQL the request path emits (US-27.11 HeavyRead is
      # pointed at AdminRepo in test, so the queries run in-process and are captured).
      captured =
        PlanAssertions.capture_repo_queries(fn ->
          {:ok, _} = Knowledge.distant_pairs(tenant.id)
        end)

      # Post-#202/#203 the request path emits exactly ONE self-join carrying the `<=>`
      # BETWEEN band — the paginated `LIMIT limit+1` page. The old companion `count(*)`
      # query (a SECOND full O(candidates²) pass that could not early-terminate and was
      # the entire prod-scale cost) is gone; asserting exactly 1 here is the scale-side
      # regression guard against its reintroduction.
      between_queries =
        Enum.filter(captured, fn {sql, _} -> sql =~ ~r/BETWEEN/i end)

      assert length(between_queries) == 1

      for {sql, params} <- between_queries do
        # No Seq Scan over the corpus: the candidate subquery is reached via an Index Scan.
        assert :ok = PlanAssertions.refute_seq_scan({sql, params})

        # The genuine bound is the `ORDER BY id LIMIT max_pair_candidates()` on the sampled
        # candidate subquery — verified at 80k the candidate `Index Scan` is dominated by a
        # `Limit rows=25` (actual consumed ≤25, ~1.7ms / ~1657 buffers — NOT an O(n²) corpus
        # read; the scan node's pre-LIMIT `Plan Rows ≈ corpus` is just an estimate, so
        # `assert_scan_rows_below` does NOT fit this shape). A regression that dropped the
        # sample LIMIT leaves the scan with no dominating `Limit ≤ cap`, tripping this.
        assert :ok =
                 PlanAssertions.assert_article_scans_capped_by_limit(
                   {sql, params},
                   @max_pair_candidates
                 )
      end
    end)
  end

  test "novelty (nearest_prior_distance) is index-bounded, not a Seq Scan over 80k",
       %{tenant: tenant} do
    unboxed(fn ->
      # First confirm the request path actually scores against a non-trivial, BOUNDED prior
      # set at 80k (the ~2% tag), so the plan we assert below is the one it really runs.
      # The idea embedding is the global stub set in setup_all (ScaleSeed.embedding_for(0)).
      idea_vec = ScaleSeed.embedding_for(0)

      {:ok, [_scored], prior_count} =
        Knowledge.novelty_scores(tenant.id, [%{text: "scale idea"}], prior_tag: @prior_tag)

      assert prior_count > 0

      # The MIN(<=>) aggregate executes inside a `Task.async_stream` (off the test process),
      # so capture_repo_queries can't see it. EXPLAIN the EXACT query builder the request
      # path uses (`novelty_distance_query/4`) with the SAME const + tag — same SQL+params.
      query = Knowledge.novelty_distance_query(tenant.id, idea_vec, @prior_tag, nil)

      # The REAL invariant is "bounded by prior-tag selectivity, NOT a full-corpus read" —
      # and there are TWO legitimate bounded plans the cost-based planner may pick, so we must
      # NOT pin the node type (the prior HIGH finding):
      #
      #   * verified at 80k via EXPLAIN ANALYZE: Postgres rewrites `MIN(embedding <=> $const)`
      #     into `ORDER BY (embedding <=> $const) LIMIT 1` and serves it from the HNSW index
      #     (`articles_embedding_hnsw_idx`), `tags &&` as an in-line Filter — a single Index
      #     Scan, ~0.3ms / 676 buffers, ~0 ACTUAL rows touched on the articles node; OR
      #   * for a less-HNSW-friendly target/stats, a `tags &&` GIN bitmap
      #     (`articles_tags_index`) — a Bitmap Heap Scan, also bounded by the ~2% tag
      #     (≤ ~1.6k ACTUAL rows at 80k).
      #
      # `refute_full_scan` would FALSE-RED the second (legitimately bounded) plan because it
      # forbids Bitmap Heap Scan. So assert the STRUCTURAL bound, accepting either plan:
      #   1. no unbounded Seq Scan (a bounded bitmap is allowed), AND
      #   2. every `articles` scan produced fewer than corpus/8 ACTUAL rows — via
      #      EXPLAIN ANALYZE, NOT the planner ESTIMATE, so a low-estimate/high-actual
      #      regression that heap-rechecks the whole corpus at runtime (the #168/#172 shape)
      #      is caught by REAL rows. Both bounded plans (HNSW ~0, GIN bitmap ~1.6k) pass;
      #      a full-corpus scan (~80k actual) trips it.
      # Ceiling = floor/8 = 10_000 (≫ the ~1.6k tag set, ≪ the 80k corpus).
      ceiling = div(ScaleSeed.prod_article_floor(), 8)

      assert :ok = PlanAssertions.refute_seq_scan(query)
      assert :ok = PlanAssertions.assert_actual_scan_rows_below(query, ceiling)
    end)
  end
end
