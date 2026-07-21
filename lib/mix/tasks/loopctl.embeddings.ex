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

  The full cutover order (see `Loopctl.Embeddings` moduledoc and
  `docs/runbooks/embedding-dimension-cutover.md`):

      1. deploy the dual-write code to EVERY node
      2. mix loopctl.embeddings backfill
      3. mix loopctl.embeddings reconcile   (and let the standing hourly worker run)
      4. mix loopctl.embeddings cutover
  """

  use Mix.Task

  @shortdoc "Operate the embedding-side-table backfill / reconciliation / cutover"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    dispatch(args)
  end

  defp dispatch(["backfill" | _]) do
    {:ok, a} = Loopctl.Embeddings.backfill_articles()
    {:ok, m} = Loopctl.Embeddings.backfill_memories()
    Mix.shell().info("articles: #{inspect(a)}")
    Mix.shell().info("memories: #{inspect(m)}")
  end

  defp dispatch(["reconcile" | _]) do
    {:ok, a} = Loopctl.Embeddings.reconcile_articles()
    {:ok, m} = Loopctl.Embeddings.reconcile_memories()
    Mix.shell().info("articles: #{inspect(a)}")
    Mix.shell().info("memories: #{inspect(m)}")
  end

  defp dispatch(["status" | _]) do
    a = length(Loopctl.Embeddings.article_reconciliation_gaps(limit: 1000))
    m = length(Loopctl.Embeddings.memory_reconciliation_gaps(limit: 1000))
    ad = length(Loopctl.Embeddings.article_live_denorm_drift(limit: 1000))
    md = length(Loopctl.Embeddings.memory_live_denorm_drift(limit: 1000))
    reads = Loopctl.Embeddings.side_table_reads_enabled?()

    Mix.shell().info("side_table_reads_enabled: #{reads}")
    Mix.shell().info("article backfill gaps (capped at 1000): #{a}")
    Mix.shell().info("memory backfill gaps (capped at 1000): #{m}")
    Mix.shell().info("article live_denorm drift (capped at 1000): #{ad}")
    Mix.shell().info("memory live_denorm drift (capped at 1000): #{md}")
  end

  defp dispatch(["cutover" | _]) do
    {:ok, _} = Loopctl.SystemConfig.put(Loopctl.Embeddings.read_flag_key(), 1)
    Mix.shell().info("side-table reads ENABLED (#{Loopctl.Embeddings.read_flag_key()} = 1)")
  end

  defp dispatch(["revert" | _]) do
    {:ok, _} = Loopctl.SystemConfig.put(Loopctl.Embeddings.read_flag_key(), 0)

    Mix.shell().info(
      "side-table reads REVERTED to legacy (#{Loopctl.Embeddings.read_flag_key()} = 0)"
    )
  end

  defp dispatch(_other) do
    Mix.shell().error("usage: mix loopctl.embeddings [backfill|reconcile|status|cutover|revert]")
    exit({:shutdown, 1})
  end
end
