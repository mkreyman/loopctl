defmodule Mix.Tasks.Loopctl.SeedScale do
  @moduledoc """
  US-27.1 — Seeds a large-corpus scale fixture for representative testing.

  Inserts N published articles (each with a deterministic 1536-dim embedding)
  and inter-article links for a given tenant into the database using
  `AdminRepo.insert_all` in batches, then runs `ANALYZE` and verifies that
  Postgres statistics reflect the seeded corpus.

  This task is designed to be run against a dedicated test/CI database
  (NOT the development database with real data). Seeded rows are committed
  directly, bypassing the test sandbox.

  ## Usage

      mix loopctl.seed_scale --tenant-id UUID [options]

  ## Options

      --tenant-id     Required. UUID of the tenant to seed under.
      --count         Number of articles to seed (default: 1_000).
                      Use --count=80000 to seed at prod scale (PROD_ARTICLE_FLOOR).
      --link-density  Average links per article (default: 5).
      --batch-size    Rows per insert_all batch (default: 1_000).
      --check-floor   When set, raises if count < PROD_ARTICLE_FLOOR (80_000 as of 2026-06-24).
                      Use this for CI scale-gate runs.
      --allow-prod    Bypass the environment guard that prevents running in non-test/dev
                      environments. Use with extreme caution — this task seeds via AdminRepo
                      (BYPASSRLS) and will write synthetic data to whatever DB is configured.

  ## Examples

      # Seed 1_000 articles for a specific tenant:
      mix loopctl.seed_scale --tenant-id aaaaaaaa-0000-0000-0000-000000000001

      # Seed at prod scale with the floor check enabled:
      mix loopctl.seed_scale --tenant-id UUID --count 80000 --check-floor

      # Seed 500 articles with 3 links/article:
      mix loopctl.seed_scale --tenant-id UUID --count 500 --link-density 3

  ## Teardown

  To remove seeded rows (e.g., after a CI run on a shared DB):

      # In iex -S mix:
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
  Postgrex to send the UUID as text — you get a `Postgrex expected a binary of 16
  bytes` error. Schema modules allow Ecto to infer the `:binary_id` type.

  ## Performance budget

  Target: < 3 min on CI hardware for PROD_ARTICLE_FLOOR (80_000) articles.
  Bottleneck is Postgres bulk ingestion. Use --batch-size to tune.
  """

  use Mix.Task

  @shortdoc "Seed large-corpus scale fixture for representative query testing"

  @impl Mix.Task
  def run(args) do
    # Safety guard: refuse to run against a production database unless the
    # caller explicitly acknowledges the risk via --allow-prod.
    # Without this check, an operator with the wrong DATABASE_URL would
    # commit ~80k synthetic published articles into a live tenant's KB via
    # the RLS-bypassing AdminRepo (BYPASSRLS).
    #
    # Allowed environments: :test, :dev, or any env with --allow-prod flag.
    env = Mix.env()

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          tenant_id: :string,
          count: :integer,
          link_density: :integer,
          batch_size: :integer,
          check_floor: :boolean,
          allow_prod: :boolean
        ]
      )

    allow_prod = Keyword.get(opts, :allow_prod, false)

    unless env in [:test, :dev] or allow_prod do
      Mix.raise("""
      mix loopctl.seed_scale refuses to run in environment #{inspect(env)}.

      This task seeds synthetic data directly via AdminRepo (BYPASSRLS), bypassing RLS.
      Running against a production database risks committing 80k+ synthetic articles
      to a real tenant's knowledge base.

      To proceed in a non-test/dev environment, pass --allow-prod to confirm intent:

          mix loopctl.seed_scale --allow-prod --tenant-id UUID --count 1000

      Recommended: run against a dedicated test/CI database only.
      """)
    end

    Mix.Task.run("app.start")

    alias Loopctl.Knowledge.ScaleSeed

    tenant_id = Keyword.get(opts, :tenant_id)

    unless tenant_id do
      Mix.raise("--tenant-id is required. Usage: mix loopctl.seed_scale --tenant-id UUID")
    end

    count = Keyword.get(opts, :count, 1_000)
    link_density = Keyword.get(opts, :link_density, 5)
    batch_size = Keyword.get(opts, :batch_size, 1_000)
    check_floor = Keyword.get(opts, :check_floor, false)

    if check_floor do
      ScaleSeed.assert_at_prod_scale!(count)

      Mix.shell().info(
        "Floor check passed: count=#{count} >= PROD_ARTICLE_FLOOR=#{ScaleSeed.prod_article_floor()}"
      )
    end

    unless ScaleSeed.hnsw_index_present?() do
      Mix.raise(
        "No HNSW index detected on articles.embedding or article_embeddings. " <>
          "Run `mix ecto.migrate` before seeding at scale; if migrations have run, " <>
          "check the embedding_side_table_reads flag — a cut-over install retires the " <>
          "legacy articles index by design (GH #578)."
      )
    end

    Mix.shell().info(
      "Seeding #{count} articles for tenant #{tenant_id} " <>
        "(link_density: #{link_density}, batch_size: #{batch_size})..."
    )

    started_at = System.monotonic_time(:millisecond)

    result =
      ScaleSeed.seed!(tenant_id, count: count, link_density: link_density, batch_size: batch_size)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    elapsed_s = Float.round(elapsed_ms / 1000, 1)

    Mix.shell().info(
      "Done. articles=#{result.articles}, links=#{result.links}, elapsed=#{elapsed_s}s"
    )

    if elapsed_ms > 180_000 do
      Mix.shell().error(
        "WARNING: seeding took #{elapsed_s}s, exceeding the 3-minute CI budget. " <>
          "Consider increasing --batch-size or using a faster DB."
      )
    end
  end
end
