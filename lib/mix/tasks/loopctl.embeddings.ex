defmodule Mix.Tasks.Loopctl.Embeddings do
  @moduledoc """
  US-41.1 (review) — the executable operator surface for the embedding-side-table
  cutover, so AC-41.1.8's cutover protocol and AC-41.1.9's backfill are runnable from
  a deploy shell rather than only from a remote IEx console.

  ## Usage

      mix loopctl.embeddings backfill      # copy legacy embeddings into the side table
      mix loopctl.embeddings reconcile      # sweep the crash-window + live_denorm drift
      mix loopctl.embeddings status         # report gaps / drift without changing anything
      mix loopctl.embeddings cutover        # flip the side-table read flag (idempotent)
      mix loopctl.embeddings revert         # revert the read flag to the legacy column
      mix loopctl.embeddings revert --force # ... even with the legacy ANN index gone

  The full cutover order (see `Loopctl.Embeddings` moduledoc and
  `docs/runbooks/embedding-dimension-cutover.md`):

      1. deploy the dual-write code to EVERY node
      2. mix loopctl.embeddings backfill
      3. mix loopctl.embeddings reconcile   (and let the standing hourly worker run)
      4. mix loopctl.embeddings cutover

  `revert` is NOT the routine toggle it once was (GH #578): migration
  `20260805120000` retires the legacy `articles.embedding` HNSW index on a
  cut-over install, so reverting there lands semantic reads on an UNINDEXED
  column. The task refuses the revert while that index is absent and prints the
  rebuild command; `--force` accepts the outage deliberately. See
  `docs/runbooks/embedding-dimension-cutover.md` (Reverting).
  """

  use Mix.Task

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Repo.HnswIndex
  alias Loopctl.SystemConfig

  @shortdoc "Operate the embedding-side-table backfill / reconciliation / cutover"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    dispatch(args)
  end

  @doc """
  Whether a VALID HNSW index still covers the LEGACY `articles.embedding` column —
  i.e. whether reverting the read flag lands on an indexed path.

  Detected by CAPABILITY (`pg_am.amname = 'hnsw'`) and by COLUMN, never by name:
  the index lives under two names historically (US-27.14), and a name check would
  read GH #578's deliberate retirement the same way it reads a broken deploy.
  `indisvalid` is checked because a failed `CREATE INDEX CONCURRENTLY` leaves a
  same-named INVALID index the planner will never use — present in `pg_indexes`,
  useless to the read path.
  """
  @spec legacy_hnsw_index_present?() :: boolean()
  def legacy_hnsw_index_present? do
    %{rows: rows} =
      AdminRepo.query!("""
      SELECT 1
      FROM pg_index i
      JOIN pg_class idx ON idx.oid = i.indexrelid
      JOIN pg_class tbl ON tbl.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = tbl.relnamespace
      JOIN pg_am am ON am.oid = idx.relam
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
      WHERE n.nspname = ANY(current_schemas(false))
        AND tbl.relname = 'articles'
        AND a.attname = 'embedding'
        AND am.amname = 'hnsw'
        AND i.indisvalid
      LIMIT 1
      """)

    rows != []
  end

  @doc """
  The operator-facing warning printed when a revert would land on an unindexed
  `articles.embedding`. Public so the runbook text and this task cannot drift.
  """
  @spec unindexed_revert_warning() :: String.t()
  def unindexed_revert_warning do
    """
    #{HnswIndex.canonical_index_name("articles")} is ABSENT: no VALID HNSW index
    covers articles.embedding on this install. Migration 20260805120000 retires it
    once reads are cut over to the side table (GH #578).

    Reverting the flag to 0 puts EVERY semantic read back on that unindexed column:
    a seq scan + top-N sort that trips the heavy-read statement_timeout. The cancel
    surfaces as 504 db_statement_timeout, NOT the heavy_read_overloaded tuple, so
    the labelled keyword degrade never matches — semantic search returns no results
    tenant-wide until the index is rebuilt.

    Rebuild FIRST. Raise maintenance_work_mem well above the 64 MB default or the
    ~657 MB HNSW build silently falls back to the slow on-disk path:

        SET maintenance_work_mem = '2GB';
        CREATE INDEX CONCURRENTLY #{HnswIndex.canonical_index_name("articles")}
          ON articles USING hnsw (embedding vector_cosine_ops)
          #{HnswIndex.with_params_clause()};
    """
  end

  defp dispatch(["backfill" | _]) do
    {:ok, a} = Embeddings.backfill_articles()
    {:ok, m} = Embeddings.backfill_memories()
    Mix.shell().info("articles: #{inspect(a)}")
    Mix.shell().info("memories: #{inspect(m)}")
  end

  defp dispatch(["reconcile" | _]) do
    {:ok, a} = Embeddings.reconcile_articles()
    {:ok, m} = Embeddings.reconcile_memories()
    Mix.shell().info("articles: #{inspect(a)}")
    Mix.shell().info("memories: #{inspect(m)}")
  end

  defp dispatch(["status" | _]) do
    a = length(Embeddings.article_reconciliation_gaps(limit: 1000))
    m = length(Embeddings.memory_reconciliation_gaps(limit: 1000))
    ad = length(Embeddings.article_live_denorm_drift(limit: 1000))
    md = length(Embeddings.memory_live_denorm_drift(limit: 1000))
    reads = Embeddings.side_table_reads_enabled?()

    Mix.shell().info("side_table_reads_enabled: #{reads}")
    Mix.shell().info("article backfill gaps (capped at 1000): #{a}")
    Mix.shell().info("memory backfill gaps (capped at 1000): #{m}")
    Mix.shell().info("article live_denorm drift (capped at 1000): #{ad}")
    Mix.shell().info("memory live_denorm drift (capped at 1000): #{md}")
    Mix.shell().info("legacy articles.embedding HNSW index: #{legacy_hnsw_index_present?()}")
  end

  defp dispatch(["cutover" | _]) do
    {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 1)
    Mix.shell().info("side-table reads ENABLED (#{Embeddings.read_flag_key()} = 1)")
  end

  # GH #578 — the revert is no longer a routine toggle on a cut-over install: the
  # index it reverts ONTO may already be retired, and the previous version of this
  # clause wrote the flag and printed plain success either way. It now refuses while
  # the legacy ANN index is missing, and names the rebuild. `--force` stays available
  # because a revert is an INCIDENT action: an operator who has decided that a slow
  # legacy path beats a wrong side-table one must still be able to take it.
  defp dispatch(["revert" | rest]) do
    cond do
      legacy_hnsw_index_present?() ->
        revert!()

      "--force" in rest ->
        Mix.shell().error(unindexed_revert_warning())
        Mix.shell().error("--force given: reverting anyway. Semantic search will time out.")
        revert!()

      true ->
        Mix.shell().error(unindexed_revert_warning())

        Mix.shell().error(
          "REFUSING to revert. Rebuild the index above and re-run, or pass --force " <>
            "to accept a tenant-wide semantic-search outage."
        )

        exit({:shutdown, 1})
    end
  end

  defp dispatch(_other) do
    Mix.shell().error("usage: mix loopctl.embeddings [backfill|reconcile|status|cutover|revert]")
    exit({:shutdown, 1})
  end

  defp revert! do
    {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 0)
    Mix.shell().info("side-table reads REVERTED to legacy (#{Embeddings.read_flag_key()} = 0)")
  end
end
