defmodule Loopctl.Workers.EmbeddingReconciliationWorker do
  @moduledoc """
  US-41.1 AC-41.1.8(i) / AC-41.1.9 (review) — the STANDING reconciliation pass that
  the cutover runbook calls for, made executable and scheduled rather than an IEx-only
  library call.

  Two classes of drift, swept every run:

    * **The dual-write crash window** — a legacy `articles.embedding` /
      `memories.embedding` written without its dim-1536 side-table mirror (the process
      died between the two writes of a pre-one-transaction path, or a legacy row
      predates the side table). `Embeddings.reconcile_articles/1` /
      `reconcile_memories/1` re-run the idempotent backfill copy and repair any
      `live_denorm` marker drift.

    * **The active-dimension gap** — a parent row with a side-table row at SOME
      dimension but NONE at the tenant's ACTIVE dimension. This is the
      write-racing-`complete_reembed`'s-sweep hole (a writer resolved the OLD dimension
      before the completion transaction and committed its insert after the sweep
      deleted that dimension), so the row is permanently absent from recall with no
      other repair path. `Embeddings.pending_reembed_articles/3` /
      `pending_reembed_memories/3` at the ACTIVE dimension enumerate exactly these
      rows; re-enqueuing the ordinary embedding workers re-embeds them at the active
      dimension.

  ## Scheduling

  Runs `mode: "all_tenants"` from the Oban crontab (hourly). It fans out one
  per-tenant job for every tenant that has embedding rows, each bounded per run, so a
  large backlog drains over successive runs rather than in one long transaction.
  """

  use Oban.Worker, queue: :knowledge, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Memory.MemoryEmbedding
  alias Loopctl.Workers.ArticleEmbeddingWorker
  alias Loopctl.Workers.MemoryEmbeddingWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"}}) do
    tenant_ids()
    |> Enum.each(fn tenant_id ->
      %{tenant_id: tenant_id}
      |> __MODULE__.new()
      |> Oban.insert()
    end)

    :ok
  end

  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id}}) when is_binary(tenant_id) do
    {:ok, _} = Embeddings.reconcile_articles(max_batches: 5)
    {:ok, _} = Embeddings.reconcile_memories(max_batches: 5)
    reenqueue_active_dimension_gaps(tenant_id)
    :ok
  end

  # Re-embed the rows the completion sweep could have stranded at a dropped dimension.
  # `pending_reembed_*/3` at the ACTIVE dimension is exactly "rows present at some other
  # dimension but none at the active one".
  defp reenqueue_active_dimension_gaps(tenant_id) do
    active = Embeddings.active_dimension(tenant_id)
    batch = 100

    articles = Embeddings.pending_reembed_articles(tenant_id, active, batch)
    memories = Embeddings.pending_reembed_memories(tenant_id, active, batch)

    Enum.each(articles, fn article ->
      %{tenant_id: tenant_id, article_id: article.id}
      |> ArticleEmbeddingWorker.new()
      |> Oban.insert()
    end)

    Enum.each(memories, fn memory ->
      %{tenant_id: tenant_id, memory_id: memory.id}
      |> MemoryEmbeddingWorker.new()
      |> Oban.insert()
    end)

    if articles != [] or memories != [] do
      Logger.info(
        "EmbeddingReconciliationWorker: tenant=#{tenant_id} re-enqueued " <>
          "#{length(articles)} article + #{length(memories)} memory active-dimension gap(s)."
      )
    end

    :ok
  end

  # Every tenant that carries ANY embedding side-table row (article OR memory).
  defp tenant_ids do
    article_tenants =
      AdminRepo.all(from(ae in ArticleEmbedding, distinct: true, select: ae.tenant_id))

    memory_tenants =
      AdminRepo.all(from(me in MemoryEmbedding, distinct: true, select: me.tenant_id))

    (article_tenants ++ memory_tenants) |> Enum.uniq()
  end
end
