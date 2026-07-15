defmodule Loopctl.Workers.PendingEmbeddingSweepWorker do
  @moduledoc """
  US-37.4 (review HIGH #1): periodic backstop that re-enqueues a per-tenant
  `Loopctl.Workers.BatchEmbeddingWorker` drainer for every tenant that still has
  un-embedded (or content-stale) records.

  ## Why a sweep is required

  All background embedding is now triggered by enqueuing the per-tenant, `unique`
  batch drainer. Oban dedups a drainer against an in-flight sibling for the same
  `(tenant, kind)`. That coalescing is the point — but it opens a narrow race:
  a record written AFTER an executing drainer's final pending-fetch (but before
  it finishes) is deduped against that still-executing job, which never sees it.
  With no re-trigger the record stays `embedding IS NULL` — indefinitely for
  MEMORIES, which (unlike articles, self-healed nightly by
  `KnowledgeLintWorker`'s orphan relink) had no other re-embed path.

  Restricting the drainer's uniqueness to non-terminal states already ensures a
  post-COMPLETION write re-enqueues; this sweep closes the remaining EXECUTING-race
  window (and any dropped enqueue) by re-enqueuing a drainer whenever pending work
  exists. Enqueues are `unique`-deduped, so a sweep tick that overlaps a live
  drainer is a cheap no-op.

  ## Scale

  The `tenant_ids_with_pending_*` readers are DISTINCT scans backed by partial
  indexes (`articles_pending_embedding_idx` / `memories_pending_embedding_idx`),
  so a tick only fans out drainers for tenants that actually have pending work —
  usually none. Runs on `:maintenance` (a fast enqueue-only dispatcher, off the
  contended `:embeddings` lane) and is itself `unique` so overlapping cron ticks
  can't stack.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60]

  require Logger

  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Workers.BatchEmbeddingWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    article_tenants = Knowledge.tenant_ids_with_pending_article_embeddings()
    memory_tenants = Memory.tenant_ids_with_pending_embeddings()

    Enum.each(article_tenants, &enqueue_drainer(&1, "article"))
    Enum.each(memory_tenants, &enqueue_drainer(&1, "memory"))

    Logger.info(
      "PendingEmbeddingSweepWorker: enqueued drainers " <>
        "article_tenants=#{length(article_tenants)} memory_tenants=#{length(memory_tenants)}"
    )

    :ok
  end

  defp enqueue_drainer(tenant_id, kind) do
    BatchEmbeddingWorker.new(%{tenant_id: tenant_id, kind: kind})
    |> Oban.insert()
  end
end
