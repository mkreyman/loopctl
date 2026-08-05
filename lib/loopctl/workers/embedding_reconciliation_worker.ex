defmodule Loopctl.Workers.EmbeddingReconciliationWorker do
  @moduledoc """
  US-41.1 AC-41.1.8(i) / AC-41.1.9 (review) — the STANDING reconciliation pass that
  the cutover runbook calls for, made executable and scheduled rather than an IEx-only
  library call.

  THREE classes of drift, swept every run. The first two both presuppose a PARTIAL write;
  the third exists because that assumption left total absence unrepairable:

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

    * **Never embedded at all** — a published article with NO side-table row at ANY
      dimension. It matches neither class above (no legacy column to mirror, no row at
      another dimension to re-point), so before this it had no repair path and was simply
      absent from every semantic search, silently and permanently.
      `Embeddings.unembedded_articles/2` enumerates them oldest-first.

      Measured on the hosted corpus 2026-08-05: **81 published articles**, oldest
      2026-06-19, all with real bodies, none carrying a legacy embedding and none carrying
      a side-table row — six weeks unsearchable while this worker ran hourly and reported
      healthy. That is the shape of a reconciler that reconciles DRIFT BETWEEN two
      representations but cannot see that both are missing.

  ## Scheduling

  Runs `mode: "all_tenants"` from the Oban crontab (hourly). It fans out one per-tenant job
  for every tenant with embedding rows **or with published articles**, each bounded per run,
  so a large backlog drains over successive runs rather than in one long transaction.

  That second condition is load-bearing: keying the fan-out only on existing embedding rows
  made the sweep structurally unable to reach the tenant that most needed it — one whose
  articles were never embedded has no rows, so it was never enqueued, so it was never
  repaired. A fan-out keyed on the artifact you are trying to create can never create it.
  """

  use Oban.Worker, queue: :knowledge, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Memory.MemoryEmbedding
  alias Loopctl.Workers.ArticleEmbeddingWorker
  alias Loopctl.Workers.MemoryEmbeddingWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"}}) do
    # The GLOBAL backfill + live_denorm repair run EXACTLY ONCE per crontab tick, here
    # — NOT once per tenant (review, finding 7). `reconcile_articles/1` /
    # `reconcile_memories/1` are tenant-UNSCOPED: the backfill is a global INSERT..SELECT
    # anti-join and `repair_*_live_denorm/0` are unconditional full-join UPDATEs over
    # every embedding row. Running them in the per-tenant branch fanned the same global
    # full-scan work out N× (once per tenant) against AdminRepo's 3-connection pool every
    # hour — the exact US-27.11 pool-starvation class the rest of this PR routes to
    # HeavyRead to avoid, and pure redundant work (tenant_id is only used by the
    # per-tenant active-dimension gap re-enqueue).
    {:ok, _} = Embeddings.reconcile_articles(max_batches: 5)
    {:ok, _} = Embeddings.reconcile_memories(max_batches: 5)

    tenant_ids()
    |> Enum.each(fn tenant_id ->
      %{tenant_id: tenant_id}
      |> __MODULE__.new()
      |> Oban.insert()
    end)

    :ok
  end

  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id}}) when is_binary(tenant_id) do
    # Per-tenant work ONLY: the active-dimension gap re-enqueue is the sole reconcile
    # step that actually reads a tenant argument. The global backfill / live_denorm
    # repair ran once in the `all_tenants` branch above.
    reenqueue_active_dimension_gaps(tenant_id)
    reenqueue_unembedded(tenant_id)
    :ok
  end

  # The THIRD drift class: never embedded at all. Both classes above presuppose a PARTIAL
  # write — one needs the legacy column populated, the other needs a row at some other
  # dimension — so an article with no embedding row anywhere matched neither and had no
  # repair path. Measured 2026-08-05: 81 published articles unsearchable since June while
  # this worker ran hourly and reported healthy.
  defp reenqueue_unembedded(tenant_id) do
    batch = 100

    case Embeddings.unembedded_articles(tenant_id, batch) do
      [] ->
        :ok

      articles ->
        Enum.each(articles, fn article ->
          %{tenant_id: tenant_id, article_id: article.id}
          |> ArticleEmbeddingWorker.new()
          |> Oban.insert()
        end)

        # Logged at :warning, not :info. A dimension gap is an expected race; an article
        # that was never embedded means an embedding job was lost or permanently discarded,
        # and the only reason the previous 81 went unnoticed for six weeks is that nothing
        # ever said so out loud.
        Logger.warning(
          "EmbeddingReconciliationWorker: tenant=#{tenant_id} found #{length(articles)} " <>
            "published article(s) with NO embedding at any dimension — invisible to semantic " <>
            "search until re-embedded. Re-enqueued (batch cap #{batch}); a persistent count " <>
            "here means the embedding jobs are failing, not that the backlog is draining."
        )

        :ok
    end
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

  # Every tenant that carries any embedding side-table row, PLUS every tenant that has
  # published articles at all.
  #
  # The second half is load-bearing and was missing. Selecting only tenants that already
  # HAVE embedding rows makes the sweep unable to reach precisely the tenant it most needs
  # to: one whose articles were never embedded has no rows, so it was never enqueued, so it
  # was never repaired — the failure is self-concealing, and a fan-out keyed on the artifact
  # you are trying to create can never produce it.
  defp tenant_ids do
    article_tenants =
      AdminRepo.all(from(ae in ArticleEmbedding, distinct: true, select: ae.tenant_id))

    memory_tenants =
      AdminRepo.all(from(me in MemoryEmbedding, distinct: true, select: me.tenant_id))

    published_article_tenants =
      AdminRepo.all(
        from(a in Article,
          where: a.status == :published,
          where: not is_nil(a.tenant_id),
          distinct: true,
          select: a.tenant_id
        )
      )

    (article_tenants ++ memory_tenants ++ published_article_tenants) |> Enum.uniq()
  end
end
