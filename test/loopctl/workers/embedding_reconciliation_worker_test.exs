defmodule Loopctl.Workers.EmbeddingReconciliationWorkerTest do
  @moduledoc """
  The reconciliation sweep's THIRD drift class: an article that was never embedded at all.

  This worker had no test file before. That is not incidental to the defect it carried — its
  two original classes both presuppose a PARTIAL write (a legacy column without its mirror, a
  row at the wrong dimension), so an article with no embedding row anywhere matched neither
  and had no repair path. Measured on the hosted corpus 2026-08-05: 81 published articles,
  oldest 2026-06-19, invisible to semantic search for six weeks while this worker ran hourly
  and reported healthy.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Workers.EmbeddingReconciliationWorker

  # Published, with NO embedding row of any kind. Built through AdminRepo rather than the
  # publish path so the inline embedding cascade never fires — that cascade is exactly what
  # is ABSENT in the production case being reproduced.
  defp published_unembedded(tenant_id, attrs \\ %{}) do
    base = %{
      title: "Article #{System.unique_integer([:positive])}",
      body: "A real body with content.",
      category: :pattern,
      status: :draft,
      tags: []
    }

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp embedding_rows(article_id) do
    AdminRepo.all(from(ae in ArticleEmbedding, where: ae.article_id == ^article_id))
  end

  describe "unembedded_articles/2" do
    test "finds a published article with no embedding row at any dimension" do
      tenant = fixture(:tenant)
      orphan = published_unembedded(tenant.id)

      assert embedding_rows(orphan.id) == [], "precondition: the article must start unembedded"

      ids = tenant.id |> Embeddings.unembedded_articles(100) |> Enum.map(& &1.id)
      assert orphan.id in ids
    end

    test "excludes an article that already has an embedding at ANY dimension" do
      # The question this class answers is EXISTENCE, not currency. An article embedded at a
      # non-active dimension is the other class's business; claiming it here would re-create
      # the same blindness one level down and double-enqueue every re-embed.
      tenant = fixture(:tenant)
      article = published_unembedded(tenant.id)

      %ArticleEmbedding{}
      |> Ecto.Changeset.change(%{
        tenant_id: tenant.id,
        article_id: article.id,
        dim: 768,
        live_denorm: false,
        embedding: List.duplicate(0.1, 768)
      })
      |> AdminRepo.insert!()

      ids = tenant.id |> Embeddings.unembedded_articles(100) |> Enum.map(& &1.id)
      refute article.id in ids
    end

    test "excludes drafts and empty bodies" do
      # A draft is not yet expected to be searchable, and an empty body cannot produce a
      # meaningful embedding — enqueuing it would be a permanent retry loop against the
      # provider rather than a repair.
      tenant = fixture(:tenant)

      draft =
        fixture(:article, %{tenant_id: tenant.id, title: "Draft", body: "b", category: :pattern})

      # The changeset requires a body, so blank it through the repo — which is also how a
      # whitespace-only body could realistically arrive (a direct write, an import).
      [empty, breaks] =
        for blank <- ["   ", "\n\t\n"] do
          tenant.id
          |> published_unembedded()
          |> Ecto.Changeset.change(%{body: blank})
          |> AdminRepo.update!()
        end

      ids = tenant.id |> Embeddings.unembedded_articles(100) |> Enum.map(& &1.id)
      refute draft.id in ids
      refute empty.id in ids
      # Bare `btrim(body)` strips SPACES ONLY, so a line-break-only body passed the filter,
      # got embedded from its title alone, and then matched search as if it had content.
      refute breaks.id in ids
    end

    test "returns the OLDEST gaps first" do
      # Oldest-first is the documented contract: an article unsearchable since June has been
      # failing longer than one ingested this morning, and a bounded run should repair the
      # longest-standing gap first. It became assertable-and-unasserted when the lookup was
      # split into an id anti-join plus a fetch-by-id -- the ORDER BY has to be repeated on
      # the second query, and nothing here would have noticed it missing.
      #
      # The rows are INSERTED newest-first and back-dated in reverse, so physical order is
      # the exact opposite of the answer. A first cut of this test created them oldest-first,
      # which made unordered output indistinguishable from ordered output: deleting the
      # ORDER BY left it green.
      tenant = fixture(:tenant)

      [newest, middle, oldest] =
        for days_ago <- [10, 20, 30] do
          at = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)

          tenant.id
          |> published_unembedded()
          |> Ecto.Changeset.change(%{inserted_at: at})
          |> AdminRepo.update!()
        end

      seeded = [oldest.id, middle.id, newest.id]
      ids = tenant.id |> Embeddings.unembedded_articles(100) |> Enum.map(& &1.id)

      assert Enum.filter(ids, &(&1 in seeded)) == seeded
    end

    test "an empty-bodied backlog cannot starve a real gap out of a bounded batch" do
      # The LIMIT is applied to EMBEDDABLE articles, not to candidate rows that are then
      # filtered. Were the empty-body test applied after the limit instead, these two older
      # blanks would consume a batch of two forever and the real gap behind them would never
      # be repaired -- a silent permanent blackout, which is the exact defect this whole
      # worker exists to close.
      tenant = fixture(:tenant)

      # One of each blank spelling: the batch of two is only consumed if BOTH are excluded.
      for {days_ago, blank} <- [{40, "   "}, {39, "\n\t\n"}] do
        at = DateTime.utc_now() |> DateTime.add(-days_ago * 86_400, :second)

        tenant.id
        |> published_unembedded()
        |> Ecto.Changeset.change(%{body: blank, inserted_at: at})
        |> AdminRepo.update!()
      end

      real =
        tenant.id
        |> published_unembedded()
        |> Ecto.Changeset.change(%{
          inserted_at: DateTime.add(DateTime.utc_now(), -38 * 86_400, :second)
        })
        |> AdminRepo.update!()

      ids = tenant.id |> Embeddings.unembedded_articles(2) |> Enum.map(& &1.id)
      assert real.id in ids
    end

    test "is tenant-isolated" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      theirs = published_unembedded(tenant_b.id)

      ids = tenant_a.id |> Embeddings.unembedded_articles(100) |> Enum.map(& &1.id)
      refute theirs.id in ids
    end
  end

  describe "perform/1 per-tenant" do
    test "re-enqueues an article that was never embedded" do
      tenant = fixture(:tenant)
      orphan = published_unembedded(tenant.id)

      assert :ok =
               EmbeddingReconciliationWorker.perform(%Oban.Job{
                 args: %{"tenant_id" => tenant.id}
               })

      # The inline Oban cascade runs the embedding worker, so the repair is observable as an
      # embedding row rather than only as an enqueue.
      assert embedding_rows(orphan.id) != [],
             "a never-embedded published article must be repaired by the sweep"
    end
  end

  describe "all_tenants fan-out" do
    test "reaches a tenant that has published articles but ZERO embedding rows" do
      # The self-concealing half of the defect: the fan-out selected only tenants that
      # already HAD embedding rows, so a tenant whose articles were never embedded was never
      # enqueued, so it was never repaired. A fan-out keyed on the artifact you are trying to
      # create can never create it.
      tenant = fixture(:tenant)
      orphan = published_unembedded(tenant.id)

      assert AdminRepo.all(from(ae in ArticleEmbedding, where: ae.tenant_id == ^tenant.id)) == [],
             "precondition: this tenant must have no embedding rows at all"

      assert :ok =
               EmbeddingReconciliationWorker.perform(%Oban.Job{args: %{"mode" => "all_tenants"}})

      assert embedding_rows(orphan.id) != [],
             "the fan-out must reach a tenant with no embedding rows, or the gap is permanent"
    end
  end
end
