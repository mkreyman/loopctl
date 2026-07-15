defmodule Loopctl.Workers.PendingEmbeddingSweepWorkerTest do
  @moduledoc """
  US-37.4 (review HIGH #1): the periodic backstop re-enqueues a per-tenant
  BatchEmbeddingWorker drainer for any tenant that still has un-embedded records,
  so a coalesced drainer deduped away after a post-drain write can't strand
  records (indefinitely for memories, which have no other re-embed path).
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Workers.BatchEmbeddingWorker
  alias Loopctl.Workers.PendingEmbeddingSweepWorker

  defp seed_memory(tenant_id) do
    now = DateTime.utc_now()

    {1, _} =
      AdminRepo.insert_all(MemorySchema, [
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          subject_id: "subj",
          text: "pending fact",
          confidence: 1.0,
          source: :explicit,
          tags: [],
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      ])

    :ok
  end

  defp seed_published_article(tenant_id, overrides) do
    now = DateTime.utc_now()

    row =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          title: "Pending Article",
          body: "body",
          category: :pattern,
          status: :published,
          scope: :tenant,
          slug: "pending-#{System.unique_integer([:positive])}",
          tags: [],
          metadata: %{},
          inserted_at: now,
          updated_at: now
        },
        overrides
      )

    {1, _} = AdminRepo.insert_all(Article, [row])
    :ok
  end

  test "enqueues a drainer for a tenant with pending memories" do
    tenant = fixture(:tenant)
    seed_memory(tenant.id)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok = PendingEmbeddingSweepWorker.perform(%Oban.Job{args: %{}})

      assert_enqueued(worker: BatchEmbeddingWorker, args: %{tenant_id: tenant.id, kind: "memory"})
    end)
  end

  test "enqueues a drainer for a tenant with a content-stale published article (embedding intact)" do
    tenant = fixture(:tenant)
    # An embedded-but-stale article: vector present, embedding_stale_at set. The
    # backstop must still re-enqueue it (review MED #2 keeps the vector alive).
    seed_published_article(tenant.id, %{
      embedding_content_hash: "abc",
      embedding_stale_at: DateTime.utc_now()
    })

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok = PendingEmbeddingSweepWorker.perform(%Oban.Job{args: %{}})

      assert_enqueued(
        worker: BatchEmbeddingWorker,
        args: %{tenant_id: tenant.id, kind: "article"}
      )
    end)
  end

  test "enqueues no drainer for a tenant that has no pending work" do
    tenant = fixture(:tenant)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok = PendingEmbeddingSweepWorker.perform(%Oban.Job{args: %{}})

      refute_enqueued(worker: BatchEmbeddingWorker, args: %{tenant_id: tenant.id, kind: "memory"})

      refute_enqueued(
        worker: BatchEmbeddingWorker,
        args: %{tenant_id: tenant.id, kind: "article"}
      )
    end)
  end
end
