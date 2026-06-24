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
      Loopctl.AdminRepo.delete_all(from l in "article_links", where: l.tenant_id == ^tenant_id)
      Loopctl.AdminRepo.delete_all(from a in "articles", where: a.tenant_id == ^tenant_id)

  ## Performance budget

  Target: < 3 min on CI hardware for PROD_ARTICLE_FLOOR (80_000) articles.
  Bottleneck is Postgres bulk ingestion. Use --batch-size to tune.
  """

  use Mix.Task

  @shortdoc "Seed large-corpus scale fixture for representative query testing"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    alias Loopctl.Knowledge.ScaleSeed

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          tenant_id: :string,
          count: :integer,
          link_density: :integer,
          batch_size: :integer,
          check_floor: :boolean
        ]
      )

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
        "No HNSW index detected on articles.embedding. " <>
          "Run `mix ecto.migrate` before seeding at scale."
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
