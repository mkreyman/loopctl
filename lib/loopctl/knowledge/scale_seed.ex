defmodule Loopctl.Knowledge.ScaleSeed do
  @moduledoc """
  Large-corpus scale fixture for representative testing.

  Inserts a configurable number of published articles with deterministic
  `vector(1536)` embeddings and inter-article links into the database
  using `AdminRepo.insert_all` in batches. Designed to be used OUTSIDE
  the DataCase async sandbox transaction — rows must be committed so that
  `ANALYZE` sees them and the Postgres planner builds accurate statistics.

  ## IMPORTANT: This helper is OPT-IN and tagged `@tag :scale`

  **NEVER** call this from a test that uses `Loopctl.DataCase` without
  explicitly opting out of the sandbox (see `AC-27.1.4`). The sandbox
  wraps everything in a rolled-back transaction, so `insert_all` + `ANALYZE`
  inside it will produce n≈0 stats — silently defeating the purpose.

  Scale tests must:

      @tag :scale
      @tag async: false

  And use `ExUnit.Case` directly (not `DataCase`).

  ## Usage

      # Insert 1_000 articles for a tenant and seed links at density 5:
      {:ok, result} = Loopctl.Knowledge.ScaleSeed.seed(tenant.id, count: 1_000)
      # result = %{articles: 1_000, links: ~5_000}

      # Minimum config for the scale gate (≥ PROD_ARTICLE_FLOOR):
      {:ok, result} = Loopctl.Knowledge.ScaleSeed.seed(tenant.id,
        count: Loopctl.Knowledge.ScaleSeed.prod_article_floor(),
        link_density: 5,
        batch_size: 1_000
      )

  ## Teardown

  Scale seeds commit rows directly to the DB. To tear down, truncate or
  delete the seeded tenant's rows:

      import Ecto.Query
      alias Loopctl.AdminRepo
      alias Loopctl.Knowledge.{Article, ArticleLink}
      alias Loopctl.Tenants.Tenant
      Ecto.Adapters.SQL.Sandbox.unboxed_run(AdminRepo, fn ->
        AdminRepo.delete_all(from l in ArticleLink, where: l.tenant_id == ^tenant_id)
        AdminRepo.delete_all(from a in Article, where: a.tenant_id == ^tenant_id)
        AdminRepo.delete_all(from t in Tenant, where: t.id == ^tenant_id)
      end)

  **IMPORTANT:** Use schema modules (`ArticleLink`, `Article`, `Tenant`), NOT raw
  string table sources (`"article_links"`, `"articles"`). Raw string sources cause
  Postgrex to send the UUID as text, but the `tenant_id` column is `uuid` type and
  Postgrex requires a 16-byte binary — you get a `Postgrex expected a binary of 16
  bytes` error. The schema modules allow Ecto to infer the `:binary_id` type and
  encode correctly.

  Or simply drop the tenant record (FK cascades not applicable due to
  `on_delete: :restrict` on article_links — delete links first, then
  articles, then tenant).

  ## Performance budget

  Target: < 3 min on CI hardware for the default PROD_ARTICLE_FLOOR seed.
  Observed on M2 Pro (dev): ~80k articles in ~60s at batch_size: 1_000.
  Embeddings are 1536-dim floats; the bottleneck is Postgres ingestion, not
  generation.

  ## Bumping PROD_ARTICLE_FLOOR

  When production grows beyond the current floor, update `@prod_article_floor`
  and note the new source/date in the comment. Tie the bump to US-27.8 gate
  calibration. The gate raises loudly if asked to assert at a count below the
  floor (AC-27.1.6).
  """

  import Ecto.Query, only: [from: 2]

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink

  # ---------------------------------------------------------------------------
  # Prod scale floor — as of 2026-06 the published article count is ~76k.
  # Source: prod `pg_stat_user_tables` snapshot taken 2026-06-24 during
  # incident post-mortem for #168/#170/#172/#173.
  #
  # HOW TO BUMP: Update the number below and the comment date/source.
  # The scale gate (`assert_at_prod_scale!/2`) raises if `count` is below
  # this floor, so bumping it tightens the CI gate automatically.
  # Tie bumps to the US-27.8 gate calibration cycle.
  # ---------------------------------------------------------------------------
  @prod_article_floor 80_000

  # The 5 Article category enum values, round-robined across seeded rows so a
  # `category =` residual filter is ~20%-selective at scale (US-27.6a plan tests).
  @scale_categories [:pattern, :convention, :decision, :finding, :reference]

  @doc "Returns the production article floor constant (as of 2026-06-24)."
  @spec prod_article_floor() :: pos_integer()
  def prod_article_floor, do: @prod_article_floor

  # ~10% of seeded rows are private agent-memory (a selective `metadata->>'visibility'`
  # residual); the rest are shared. agent_id round-robined over 7 so a single agent's
  # visibility scope is also selective.
  defp visibility_metadata(i) when rem(i, 10) == 0,
    do: %{"visibility" => "private", "agent_id" => "scale-agent-#{rem(i, 7)}"}

  defp visibility_metadata(_i), do: %{"visibility" => "shared"}

  # Status distribution. Default: all `:published` (US-27.1/27.2/27.6a scale tests
  # assume a fully-published corpus, so this must not change for them). With
  # `status_mix: true` (US-27.9a keyset plan test), interleave ~20% non-published
  # (~10% `:archived`, ~10% `:draft`) so the keyset query's `status = :published`
  # residual has REAL selectivity — the walk must then skip index entries that don't
  # match, exercising the deep-page cost the all-published seed hides.
  defp seed_status(_i, false), do: :published
  defp seed_status(i, true) when rem(i, 10) == 0, do: :archived
  defp seed_status(i, true) when rem(i, 10) == 5, do: :draft
  defp seed_status(_i, true), do: :published

  @doc """
  Seeds `count` published articles for `tenant_id`, seeds inter-article links,
  runs ANALYZE, and verifies statistics.

  ## Options

  - `:count` — number of articles to seed (default: 1_000)
  - `:link_density` — average links per article (default: 5)
  - `:batch_size` — rows per `insert_all` batch (default: 1_000)

  Returns `{:ok, %{articles: integer(), links: integer()}}` on success,
  where `:articles` is the number of rows **actually committed** (not the
  requested count). A re-seed of the same tenant will return `articles: 0`
  due to `on_conflict: :nothing`.

  ## GUARD: sandbox usage

  This function raises `RuntimeError` if called while AdminRepo has an active
  sandbox checkout — doing so would defeat the purpose (ANALYZE would see 0
  rows post-rollback). Always call from a `@tag :scale` test that has NOT
  started a sandbox checkout for the inserted tenant's data.
  """
  @spec seed(binary(), keyword()) ::
          {:ok, %{articles: non_neg_integer(), links: non_neg_integer()}}
          | {:error, term()}
  def seed(tenant_id, opts \\ []) when is_binary(tenant_id) do
    # Guard: refuse to run inside an open transaction. ScaleSeed must run UNBOXED
    # (committed) — inside the DataCase async sandbox every insert_all + ANALYZE is
    # rolled back, so ANALYZE sees n≈0 and the planner builds bogus stats. The seed
    # opens no transaction of its own (insert_all per batch), so `in_transaction?/0`
    # being true means we're inside the sandbox's wrapping transaction (or some other
    # caller transaction) — exactly the misuse this guard exists to prevent. This is
    # functional, unlike the prior checked_out?/sentinel approaches (both no-ops): the
    # correct usage (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`) runs with no open
    # transaction, so the guard passes there.
    if AdminRepo.in_transaction?() do
      raise """
      ScaleSeed.seed/2 was called inside an open transaction (e.g. the DataCase
      async SQL sandbox). Rows inserted in a sandbox transaction are rolled back, so
      ANALYZE sees n≈0 and verify_stats! produces confusing false-RED results.

      Call ScaleSeed.seed/2 from a @tag :scale test that uses ExUnit.Case directly
      (not DataCase) and wraps DB ops in Ecto.Adapters.SQL.Sandbox.unboxed_run/2.
      See the ScaleSeed moduledoc for the correct test setup.
      """
    end

    count = Keyword.get(opts, :count, 1_000)
    link_density = Keyword.get(opts, :link_density, 5)
    batch_size = Keyword.get(opts, :batch_size, 1_000)
    status_mix = Keyword.get(opts, :status_mix, false)

    with :ok <- assert_hnsw_index_present!(),
         {:ok, article_ids} <-
           insert_articles_in_batches(tenant_id, count, batch_size, status_mix),
         {:ok, link_count} <- seed_links(tenant_id, article_ids, link_density),
         :ok <- analyze_and_verify(tenant_id, length(article_ids)) do
      {:ok, %{articles: length(article_ids), links: link_count}}
    end
  end

  @doc """
  Like `seed/2` but raises on any error. Convenience for Mix tasks.
  """
  @spec seed!(binary(), keyword()) :: %{articles: non_neg_integer(), links: non_neg_integer()}
  def seed!(tenant_id, opts \\ []) do
    case seed(tenant_id, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise "ScaleSeed failed: #{inspect(reason)}"
    end
  end

  @doc """
  Asserts that `count` is at or above `prod_article_floor/0`.
  Raises with a clear message if below — the scale gate must never run at
  sub-prod scale (AC-27.1.6).
  """
  @spec assert_at_prod_scale!(non_neg_integer(), keyword()) :: :ok
  def assert_at_prod_scale!(count, opts \\ []) do
    floor = Keyword.get(opts, :floor, @prod_article_floor)

    if count < floor do
      raise """
      Scale gate seed below prod floor!

      Requested count: #{count}
      PROD_ARTICLE_FLOOR: #{floor} (as of 2026-06-24)

      The scale gate must always run with count >= PROD_ARTICLE_FLOOR to
      reproduce the planner behaviour seen in production. Bump count, or
      update @prod_article_floor in Loopctl.Knowledge.ScaleSeed if prod
      has grown (see module doc for bump instructions).
      """
    end

    :ok
  end

  @doc """
  Returns `true` if an HNSW index on `articles.embedding` is present,
  detected by capability rather than by a hard-coded index name.

  Queries `pg_indexes JOIN pg_am` for `amname = 'hnsw'` to tolerate
  index-name drift between environments (e.g. `articles_embedding_idx`
  in test vs `articles_embedding_hnsw_idx` in prod).
  """
  @spec hnsw_index_present?() :: boolean()
  def hnsw_index_present? do
    %{rows: rows} =
      AdminRepo.query!("""
      SELECT 1
      FROM pg_indexes idx
      JOIN pg_class cls ON cls.relname = idx.indexname
      JOIN pg_am am ON am.oid = cls.relam
      WHERE idx.tablename = 'articles'
        AND am.amname = 'hnsw'
      LIMIT 1
      """)

    rows != []
  end

  # ---------------------------------------------------------------------------
  # Deterministic embedding generation (AC-27.1.2)
  # ---------------------------------------------------------------------------

  @doc """
  Returns a deterministic, L2-normalized 1536-dim embedding for row `index`.

  Embeddings are constructed so that **index-adjacent rows are also
  vector-nearest-neighbours** (high cosine similarity). This is achieved by
  blending a slowly-rotating "smooth" component (a sine wave over the index)
  with a high-frequency pseudo-random component seeded from `{index, dim}`.
  The smooth component dominates, giving articles at index `i` and `i+1` a
  cosine similarity ≈ 0.99; articles at index `i` and `i+k` fall off as
  `cos(k/period * π/2)`. The random component breaks exact ties.

  This property ensures that the link seeding in `seed_links/3`, which links
  each article to index-adjacent articles, produces a graph that is also a
  *vector* nearest-neighbour graph — satisfying AC-27.1.3.

  ## Properties

  - Deterministic: `embedding_for(i) == embedding_for(i)` for all i
  - Distinct: `embedding_for(i) != embedding_for(i+1)` for all i
  - L2-normalized: `norm(embedding_for(i)) ≈ 1.0`
  - Index-adjacent ≈ cosine-nearest: cosine(i, i+1) ≫ cosine(i, i+k) for k≫1
  - Dimension: always `embedding_dimensions` config (default 1536)
  """
  @spec embedding_for(non_neg_integer()) :: [float()]
  def embedding_for(index) do
    dims = Application.get_env(:loopctl, :embedding_dimensions, 1_536)

    # Smooth component: sine wave over index. The period is 1000 so that
    # articles within ~50 index positions share a dominant direction.
    # Using a per-dimension phase shift (2*pi*d/dims) distributes the
    # smooth signal across the full hypersphere.
    period = 1_000
    smooth_weight = 0.95
    noise_weight = 0.05
    max = 1_000_000

    floats =
      for d <- 0..(dims - 1) do
        phase = 2.0 * :math.pi() * d / dims
        smooth = :math.sin(2.0 * :math.pi() * index / period + phase)

        # High-frequency noise component — breaks exact ties so distinct
        # indices never produce identical vectors.
        noise_seed = :erlang.phash2({index, d}, max)
        noise = noise_seed / max * 2.0 - 1.0

        smooth * smooth_weight + noise * noise_weight
      end

    l2_normalize(floats)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp assert_hnsw_index_present! do
    if hnsw_index_present?() do
      :ok
    else
      {:error,
       "No HNSW index on articles.embedding detected via pg_indexes/pg_am. " <>
         "Run migrations (mix ecto.migrate) before seeding at scale. " <>
         "Scale assertions are meaningless without the index."}
    end
  end

  defp insert_articles_in_batches(tenant_id, total_count, batch_size, status_mix) do
    article_ids =
      0..(total_count - 1)
      |> Enum.chunk_every(batch_size)
      |> Enum.flat_map(fn chunk ->
        # Timestamp is computed per-batch so that articles in different batches
        # have distinct inserted_at values. This exercises the (inserted_at, id)
        # keyset tie-break path in US-27.9 pagination — if all articles share one
        # timestamp, the keyset degenerates to ordering purely by id and the
        # tie-break branch is never hit.
        now = DateTime.utc_now()

        rows =
          Enum.map(chunk, fn i ->
            id = Ecto.UUID.generate()

            # Embed as %Pgvector{} so insert_all dumps it correctly via
            # the Pgvector.Ecto.Vector type. Pgvector.new/1 wraps a list.
            embedding = Pgvector.new(embedding_for(i))

            # Slug is deterministic from tenant_id + index to avoid collisions
            # across multiple seed runs (on_conflict: :nothing handles dups).
            slug = "scale-seed-#{:erlang.phash2({tenant_id, i})}-#{i}"

            %{
              id: id,
              tenant_id: tenant_id,
              title: "ScaleSeed Article #{i}",
              body: "Scale seed body for article #{i}. Generated by ScaleSeed for load testing.",
              # SELECTIVE category/tags/visibility (US-27.6a): vary these so a residual
              # filter on the index-ordered ANN query (`tags &&`, `category =`,
              # `metadata->>'visibility'`) has REAL selectivity at scale — otherwise a
              # plan assertion on those residuals is vacuous (a filter matching 100%/0%
              # of rows never makes the planner reconsider the HNSW path). Round-robin
              # category over the 5 enum values (~20% each); one tag of 50 (~2% per tag);
              # ~10% private memory. NB: suggested_links / US-27.1 / US-27.2 scale tests
              # don't filter on these, so the variation doesn't change their plans.
              category: Enum.at(@scale_categories, rem(i, length(@scale_categories))),
              status: seed_status(i, status_mix),
              slug: slug,
              tags: ["scale-tag-#{rem(i, 50)}"],
              metadata: visibility_metadata(i),
              embedding: embedding,
              inserted_at: now,
              updated_at: now
            }
          end)

        # Use the schema module (not a raw string) so Ecto knows column types
        # and Postgrex encodes UUIDs as 16-byte binary rather than strings.
        {_count, returned} =
          AdminRepo.insert_all(Article, rows,
            returning: [:id],
            on_conflict: :nothing
          )

        Enum.map(returned, & &1.id)
      end)

    {:ok, article_ids}
  end

  defp seed_links(_tenant_id, _article_ids, 0), do: {:ok, 0}

  defp seed_links(tenant_id, article_ids, link_density) do
    now = DateTime.utc_now()
    count = length(article_ids)

    # Convert article_ids list to tuple for O(1) random access.
    # Enum.at/2 on a list is O(n), making link seeding O(n^2 * density)
    # at prod-floor scale (80k * 5 ≈ 1.6e10 traversals).
    article_ids_tuple = List.to_tuple(article_ids)

    # For each article, link to `link_density` nearest neighbours by index.
    # See `build_link_row/7` for the no-wrap nearest-neighbor strategy that
    # satisfies AC-27.1.3.
    link_rows =
      article_ids
      |> Enum.with_index()
      |> Enum.flat_map(fn {source_id, i} ->
        build_link_rows(source_id, i, count, link_density, article_ids_tuple, tenant_id, now)
      end)
      # Remove self-links defensively (the no-wrap formula never produces them
      # for link_density < count, but guard against edge cases)
      |> Enum.reject(fn row -> row.source_article_id == row.target_article_id end)

    # Insert in batches to avoid statement size limits
    inserted =
      link_rows
      |> Enum.chunk_every(1_000)
      |> Enum.reduce(0, fn batch, acc ->
        # Use schema module so Ecto encodes UUIDs correctly (binary, not string)
        {n, _} =
          AdminRepo.insert_all(ArticleLink, batch, on_conflict: :nothing)

        acc + n
      end)

    {:ok, inserted}
  end

  # Build the link rows for one source article to its `link_density` nearest
  # neighbours.
  #
  # Strategy — no-wrap nearest-neighbor (AC-27.1.3):
  # The embeddings use a sine wave of period 1_000. Articles at physical indices
  # i and (i+j) have cosine similarity ≈ cos(2π·j/1_000), which is > 0.9 for
  # any j <= 71. We must NOT use rem(i+j, count) for this: when count < period,
  # the wrap maps index i=499 to index 0 — an angular distance of ~499 steps,
  # yielding cosine ≈ -0.998 and violating AC-27.1.3.
  #
  # Instead: link forward (i+j) when room exists, link backward (i-j) otherwise.
  # Maximum index distance is always <= link_density << 71, so cosine >> 0.9.
  defp build_link_rows(source_id, i, count, link_density, article_ids_tuple, tenant_id, now) do
    relationship_type = :relates_to

    for j <- 1..link_density do
      target_idx = if i + j < count, do: i + j, else: i - j
      target_id = elem(article_ids_tuple, target_idx)

      %{
        id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        source_article_id: source_id,
        target_article_id: target_id,
        relationship_type: relationship_type,
        metadata: %{},
        inserted_at: now
      }
    end
  end

  defp analyze_and_verify(tenant_id, inserted_count) do
    # Capture last_analyze BEFORE running ANALYZE so we can assert it advanced.
    pre_analyze_ts = fetch_last_analyze()

    # Run ANALYZE on both tables so the planner has fresh statistics.
    # ANALYZE is non-transactional and sees only committed rows.
    AdminRepo.query!("ANALYZE articles")
    AdminRepo.query!("ANALYZE article_links")

    # Verify pg_stat_user_tables reflects the seeded corpus (AC-27.1.5).
    verify_stats!(tenant_id, inserted_count, pre_analyze_ts)
  end

  # Fetch last_analyze from pg_stat_user_tables for the articles table.
  # Returns nil when the table has never been analyzed.
  defp fetch_last_analyze do
    %{rows: rows} =
      AdminRepo.query!("""
      SELECT last_analyze
      FROM pg_stat_user_tables
      WHERE relname = 'articles'
      """)

    case rows do
      [[ts]] -> ts
      _ -> nil
    end
  end

  defp verify_stats!(tenant_id, inserted_count, pre_analyze_ts) do
    # pg_stat_user_tables is refreshed by the stats collector asynchronously.
    # Poll with a short bounded retry to tolerate the propagation lag on idle
    # or freshly started stats collectors.
    poll_verify_stats(tenant_id, inserted_count, pre_analyze_ts, _attempts = 5, _delay_ms = 200)
  end

  defp poll_verify_stats(tenant_id, inserted_count, pre_analyze_ts, 0, _delay_ms) do
    # Final attempt — run the check and propagate whatever result we get.
    do_verify_stats(tenant_id, inserted_count, pre_analyze_ts)
  end

  defp poll_verify_stats(tenant_id, inserted_count, pre_analyze_ts, attempts, delay_ms) do
    case do_verify_stats(tenant_id, inserted_count, pre_analyze_ts) do
      :ok ->
        :ok

      {:error, _reason} ->
        # Stats subsystem may not have flushed yet — wait and retry.
        Process.sleep(delay_ms)
        poll_verify_stats(tenant_id, inserted_count, pre_analyze_ts, attempts - 1, delay_ms * 2)
    end
  end

  defp do_verify_stats(tenant_id, inserted_count, pre_analyze_ts) do
    # Tenant-scoped committed row count gives an exact assertion that THIS
    # seed's rows reached the planner — table-wide n_live_tup can pass
    # spuriously on shared/re-used DBs where other tenants have rows.
    actual_count =
      AdminRepo.one!(
        from a in Article,
          where: a.tenant_id == ^tenant_id and a.status == :published,
          select: count(a.id)
      )

    %{rows: rows} =
      AdminRepo.query!("""
      SELECT n_live_tup, last_analyze
      FROM pg_stat_user_tables
      WHERE relname = 'articles'
      """)

    case rows do
      [[n_live_tup, last_analyze]] ->
        check_stat_values(
          tenant_id,
          inserted_count,
          actual_count,
          n_live_tup,
          last_analyze,
          pre_analyze_ts
        )

      _ ->
        {:error, "pg_stat_user_tables query returned unexpected shape: #{inspect(rows)}"}
    end
  end

  defp check_stat_values(_tenant_id, _inserted_count, _actual_count, _n_live_tup, nil, nil) do
    # last_analyze is nil and pre_analyze_ts was also nil → this is a
    # never-analyzed table. The stats collector has not yet flushed the
    # result of the ANALYZE we just ran. Caller will retry.
    {:error,
     "ANALYZE did not run on articles table — last_analyze is nil. " <>
       "This usually means the table was not yet analyzed after the bulk insert. " <>
       "Try running ANALYZE manually or check AdminRepo connectivity."}
  end

  defp check_stat_values(
         _tenant_id,
         _inserted_count,
         _actual_count,
         _n_live_tup,
         nil,
         _pre_analyze_ts
       ) do
    # Same nil case but we had a non-nil pre_analyze_ts — stats collector
    # transiently returned nil. Caller will retry.
    {:error,
     "ANALYZE did not run on articles table — last_analyze is nil. " <>
       "This usually means the table was not yet analyzed after the bulk insert. " <>
       "Try running ANALYZE manually or check AdminRepo connectivity."}
  end

  defp check_stat_values(
         tenant_id,
         inserted_count,
         actual_count,
         _n_live_tup,
         _last_analyze,
         _pre_analyze_ts
       )
       when actual_count < inserted_count do
    # Exact tenant-scoped count is below what was inserted — either the seed
    # genuinely inserted fewer rows (on_conflict: :nothing dups) or this is
    # a logic error. Surface the discrepancy so callers know the DB state.
    {:error,
     "Tenant-scoped article count (#{actual_count}) is below inserted count (#{inserted_count}) " <>
       "for tenant #{tenant_id}. Seeded rows may not have committed or were deduplicated by " <>
       "on_conflict: :nothing. Ensure seeding runs OUTSIDE the DataCase sandbox."}
  end

  defp check_stat_values(
         _tenant_id,
         _inserted_count,
         _actual_count,
         n_live_tup,
         last_analyze,
         pre_analyze_ts
       ) do
    # last_analyze advanced past pre_analyze_ts (or pre was nil) — ANALYZE ran.
    analyze_advanced? =
      is_nil(pre_analyze_ts) or
        case DateTime.compare(last_analyze, pre_analyze_ts) do
          :gt -> true
          _ -> false
        end

    cond do
      not analyze_advanced? ->
        {:error,
         "pg_stat_user_tables.last_analyze (#{inspect(last_analyze)}) did not advance " <>
           "past pre-ANALYZE timestamp (#{inspect(pre_analyze_ts)}). " <>
           "The stats collector may be lagging — retry or check connectivity."}

      n_live_tup == 0 ->
        {:error,
         "pg_stat_user_tables n_live_tup is 0 after ANALYZE. " <>
           "Ensure seeding runs OUTSIDE the DataCase sandbox."}

      true ->
        :ok
    end
  end

  defp l2_normalize(floats) do
    norm = floats |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

    if norm == 0.0 do
      # Degenerate zero vector: return unit vector along first dimension
      [1.0 | List.duplicate(0.0, length(floats) - 1)]
    else
      Enum.map(floats, &(&1 / norm))
    end
  end
end
